/// Lexical SQL statement splitter for PostgreSQL.
/// Correctly splits SQL scripts into individual statements without splitting on
/// semicolons inside single quotes, double quotes, dollar-quoted blocks ($$ or $tag$),
/// line comments (--), or nested block comments (/* ... */).
pub fn split_statements(sql: &str) -> Vec<String> {
    let mut statements = Vec::new();
    let mut current = String::new();

    let chars: Vec<char> = sql.chars().collect();
    let len = chars.len();
    let mut i = 0;

    #[derive(PartialEq)]
    enum State {
        Normal,
        SingleQuote,
        DoubleQuote,
        LineComment,
        BlockComment(usize), // nesting depth
        DollarQuote(String), // tag, e.g. "" for $$, or "tag" for $tag$
    }

    let mut state = State::Normal;

    while i < len {
        let c = chars[i];

        match state {
            State::Normal => {
                if c == '-' && i + 1 < len && chars[i + 1] == '-' {
                    // Line comment
                    current.push(c);
                    current.push(chars[i + 1]);
                    i += 2;
                    state = State::LineComment;
                    continue;
                } else if c == '/' && i + 1 < len && chars[i + 1] == '*' {
                    // Block comment
                    current.push(c);
                    current.push(chars[i + 1]);
                    i += 2;
                    state = State::BlockComment(1);
                    continue;
                } else if c == '\'' {
                    current.push(c);
                    i += 1;
                    state = State::SingleQuote;
                    continue;
                } else if c == '"' {
                    current.push(c);
                    i += 1;
                    state = State::DoubleQuote;
                    continue;
                } else if c == '$' {
                    // Check for dollar quote tag: $[a-zA-Z0-9_]*$
                    if let Some((tag, end_idx)) = parse_dollar_tag(&chars, i) {
                        for k in i..end_idx {
                            current.push(chars[k]);
                        }
                        i = end_idx;
                        state = State::DollarQuote(tag);
                        continue;
                    } else {
                        current.push(c);
                        i += 1;
                        continue;
                    }
                } else if c == ';' {
                    let trimmed = current.trim();
                    if !trimmed.is_empty() {
                        statements.push(trimmed.to_string());
                    }
                    current.clear();
                    i += 1;
                    continue;
                } else {
                    current.push(c);
                    i += 1;
                }
            }
            State::SingleQuote => {
                current.push(c);
                if c == '\'' {
                    // Check for escaped quote: ''
                    if i + 1 < len && chars[i + 1] == '\'' {
                        current.push(chars[i + 1]);
                        i += 2;
                        continue;
                    } else {
                        state = State::Normal;
                    }
                }
                i += 1;
            }
            State::DoubleQuote => {
                current.push(c);
                if c == '"' {
                    // Check for escaped quote: ""
                    if i + 1 < len && chars[i + 1] == '"' {
                        current.push(chars[i + 1]);
                        i += 2;
                        continue;
                    } else {
                        state = State::Normal;
                    }
                }
                i += 1;
            }
            State::LineComment => {
                current.push(c);
                if c == '\n' {
                    state = State::Normal;
                }
                i += 1;
            }
            State::BlockComment(depth) => {
                if c == '/' && i + 1 < len && chars[i + 1] == '*' {
                    current.push(c);
                    current.push(chars[i + 1]);
                    i += 2;
                    state = State::BlockComment(depth + 1);
                    continue;
                } else if c == '*' && i + 1 < len && chars[i + 1] == '/' {
                    current.push(c);
                    current.push(chars[i + 1]);
                    i += 2;
                    if depth == 1 {
                        state = State::Normal;
                    } else {
                        state = State::BlockComment(depth - 1);
                    }
                    continue;
                } else {
                    current.push(c);
                    i += 1;
                }
            }
            State::DollarQuote(ref tag) => {
                if c == '$' {
                    if let Some((closing_tag, end_idx)) = parse_dollar_tag(&chars, i) {
                        if &closing_tag == tag {
                            for k in i..end_idx {
                                current.push(chars[k]);
                            }
                            i = end_idx;
                            state = State::Normal;
                            continue;
                        }
                    }
                }
                current.push(c);
                i += 1;
            }
        }
    }

    let trimmed = current.trim();
    if !trimmed.is_empty() {
        statements.push(trimmed.to_string());
    }

    statements
}

/// Extracts the first significant SQL keyword, skipping leading whitespace,
/// parentheses, line comments (--), and block comments (/* ... */, including nested ones).
pub fn extract_first_keyword(sql: &str) -> Option<String> {
    let chars: Vec<char> = sql.chars().collect();
    let len = chars.len();
    let mut i = 0;

    while i < len {
        let c = chars[i];
        if c.is_whitespace() || c == '(' || c == ')' {
            i += 1;
            continue;
        }
        if c == '-' && i + 1 < len && chars[i + 1] == '-' {
            // Line comment, skip to newline
            i += 2;
            while i < len && chars[i] != '\n' {
                i += 1;
            }
            continue;
        }
        if c == '/' && i + 1 < len && chars[i + 1] == '*' {
            // Block comment, skip to */ handling nested block comments
            i += 2;
            let mut depth = 1;
            while i < len && depth > 0 {
                if chars[i] == '/' && i + 1 < len && chars[i + 1] == '*' {
                    depth += 1;
                    i += 2;
                } else if chars[i] == '*' && i + 1 < len && chars[i + 1] == '/' {
                    depth -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            continue;
        }
        if c.is_alphabetic() || c == '_' {
            let start = i;
            while i < len && (chars[i].is_alphanumeric() || chars[i] == '_') {
                i += 1;
            }
            let word: String = chars[start..i].iter().collect();
            return Some(word.to_uppercase());
        }
        i += 1;
    }
    None
}

/// Helper to parse a dollar quote tag: starts at `chars[start] == '$'`,
/// followed by optional identifier characters, ending with `'$'`.
/// Returns `Some((tag, next_index))` if a valid tag is found.
fn parse_dollar_tag(chars: &[char], start: usize) -> Option<(String, usize)> {
    if chars.get(start) != Some(&'$') {
        return None;
    }
    let mut j = start + 1;
    let mut tag = String::new();
    while j < chars.len() {
        let ch = chars[j];
        if ch == '$' {
            return Some((tag, j + 1));
        } else if ch.is_ascii_alphanumeric() || ch == '_' {
            tag.push(ch);
            j += 1;
        } else {
            // Not a valid tag syntax (e.g. `$1` parameter)
            return None;
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_single_statement() {
        let stmts = split_statements("SELECT 1;");
        assert_eq!(stmts, vec!["SELECT 1"]);
    }

    #[test]
    fn test_multiple_statements() {
        let stmts = split_statements("SELECT 1; SELECT 2; SELECT 3;");
        assert_eq!(stmts, vec!["SELECT 1", "SELECT 2", "SELECT 3"]);
    }

    #[test]
    fn test_semicolon_in_string_literal() {
        let stmts = split_statements("INSERT INTO t VALUES ('hello; world'); SELECT * FROM t;");
        assert_eq!(
            stmts,
            vec![
                "INSERT INTO t VALUES ('hello; world')",
                "SELECT * FROM t"
            ]
        );
    }

    #[test]
    fn test_escaped_quotes() {
        let stmts = split_statements("SELECT 'it''s; cool'; SELECT 42;");
        assert_eq!(stmts, vec!["SELECT 'it''s; cool'", "SELECT 42"]);
    }

    #[test]
    fn test_dollar_quoted_block() {
        let sql = r#"
            CREATE FUNCTION test() RETURNS void AS $$
            BEGIN
                SELECT 1;
                UPDATE foo SET x = 2;
            END;
            $$ LANGUAGE plpgsql;
            SELECT 42;
        "#;
        let stmts = split_statements(sql);
        assert_eq!(stmts.len(), 2);
        assert!(stmts[0].starts_with("CREATE FUNCTION"));
        assert!(stmts[0].contains("SELECT 1;"));
        assert_eq!(stmts[1], "SELECT 42");
    }

    #[test]
    fn test_tagged_dollar_quote() {
        let sql = "SELECT $tag$ semicolon; inside $tag$; SELECT 2;";
        let stmts = split_statements(sql);
        assert_eq!(stmts, vec!["SELECT $tag$ semicolon; inside $tag$", "SELECT 2"]);
    }

    #[test]
    fn test_comments() {
        let sql = r#"
            -- comment; here
            SELECT 1;
            /* block; /* nested; */ comment */
            SELECT 2;
        "#;
        let stmts = split_statements(sql);
        assert_eq!(stmts.len(), 2);
    }

    #[test]
    fn test_double_quotes() {
        let sql = r#"SELECT "col;name" FROM "my;table"; SELECT 1;"#;
        let stmts = split_statements(sql);
        assert_eq!(stmts, vec![r#"SELECT "col;name" FROM "my;table""#, "SELECT 1"]);
    }

    #[test]
    fn test_extract_first_keyword() {
        assert_eq!(extract_first_keyword("SELECT * FROM foo;"), Some("SELECT".into()));
        assert_eq!(extract_first_keyword("   insert into foo"), Some("INSERT".into()));
        assert_eq!(extract_first_keyword("-- line comment\nUPDATE foo"), Some("UPDATE".into()));
        assert_eq!(extract_first_keyword("/* outer /* inner */ */ DELETE FROM foo"), Some("DELETE".into()));
        assert_eq!(extract_first_keyword("/* comment */ -- line\n  BEGIN;"), Some("BEGIN".into()));
        assert_eq!(extract_first_keyword("(SELECT 1)"), Some("SELECT".into()));
        assert_eq!(extract_first_keyword("/* only comment */ -- nothing"), None);
    }
}
