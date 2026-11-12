use thiserror::Error;

#[derive(uniffi::Error, Error, Debug, PartialEq)]
pub enum LucidError {
    #[error("Connection failed: {reason}")]
    ConnectionFailed { reason: String },
    #[error("Authentication failed: {message}")]
    AuthenticationFailed { message: String },
    #[error("Query was cancelled by user")]
    QueryCancelled,
    #[error("Query timed out after {duration_ms}ms")]
    QueryTimedOut { duration_ms: u64 },
    #[error("Read-only mode violation: {attempted_operation}")]
    ReadOnlyViolation { attempted_operation: String },
    #[error("Concurrent modification detected for table {table_name}")]
    ConflictDetected { table_name: String, primary_key_values: Vec<String> },
    #[error("Table {table_name} has no primary key")]
    MissingPrimaryKey { table_name: String },
    #[error("Commit outcome uncertain due to network failure: {message}")]
    UncertainCommitOutcome { message: String },
    #[error("Database error ({code}): {message}")]
    DatabaseError { code: String, message: String, detail: Option<String> },
}
