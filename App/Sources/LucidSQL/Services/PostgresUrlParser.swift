import Foundation

public struct ParsedPostgresUrl: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let database: String
    public let user: String
    public let password: String?
    public let sslMode: String?
    public let sslRootCert: String?
    public let timeoutSeconds: UInt32?
}

public enum PostgresUrlParseError: Error, LocalizedError, Equatable {
    case emptyInput
    case invalidWhitespace
    case fragmentNotSupported
    case missingScheme
    case unsupportedScheme(String)
    case unescapedQuestionMarkInCredentials
    case multipleAtSignsInAuthority
    case emptyUserInfo
    case missingUsername
    case malformedIPv6(String)
    case multiHostNotSupported
    case missingHost
    case invalidPort(String)
    case malformedDatabasePath
    case malformedQueryParameter(String)
    case invalidPercentEncoding(component: String)
    case nullCharacterNotAllowed(component: String)
    case unsupportedSslMode(String)
    case conflictingParameter(String)
    case invalidSslRootCert(String)
    case invalidConnectTimeout(String)
    case unsupportedParameters([String])

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Enter a postgres:// or postgresql:// connection URL to import."
        case .invalidWhitespace:
            return "Connection URL cannot contain spaces or line breaks. Encode spaces in values as %20."
        case .fragmentNotSupported:
            return "URL fragments ('#...') are not supported. If your password contains '#', percent-encode it as %23."
        case .missingScheme:
            return "Malformed URL: expected a postgres:// or postgresql:// scheme."
        case .unsupportedScheme(let scheme):
            return "Unsupported URL scheme '\(scheme)://'. Only postgres:// and postgresql:// are supported."
        case .unescapedQuestionMarkInCredentials:
            return "Malformed URL: unescaped '?' before '@'. Percent-encode '?' in usernames or passwords as %3F."
        case .multipleAtSignsInAuthority:
            return "Malformed URL authority: multiple '@' characters found. Percent-encode '@' in usernames or passwords as %40."
        case .emptyUserInfo:
            return "Empty credentials before '@' in URL. Remove '@' or provide a username."
        case .missingUsername:
            return "Missing username before ':' in URL credentials."
        case .malformedIPv6(let detail):
            return detail
        case .multiHostNotSupported:
            return "Multi-host PostgreSQL URLs (comma-separated hosts) are not supported. Specify a single host."
        case .missingHost:
            return "Missing host in connection URL. Unix domain socket URLs without a host are not supported; specify a host such as localhost or [::1]."
        case .invalidPort(let raw):
            return "Invalid port '\(raw)'. Port must be an integer between 1 and 65535."
        case .malformedDatabasePath:
            return "Malformed database path: unexpected extra '/' after the database name."
        case .malformedQueryParameter(let name):
            return "Malformed query parameter '\(name)': expected key=value."
        case .invalidPercentEncoding(let component):
            return "Invalid percent-encoding in \(component)."
        case .nullCharacterNotAllowed(let component):
            return "Null byte (%00) is not allowed in \(component)."
        case .unsupportedSslMode(let mode):
            return "Unsupported sslmode '\(mode)'. Supported modes: disable, prefer, require, verify-ca, verify-full."
        case .conflictingParameter(let param):
            return "Conflicting '\(param)' specified in both the URL and query parameters."
        case .invalidSslRootCert(let detail):
            return detail
        case .invalidConnectTimeout(let detail):
            return detail
        case .unsupportedParameters(let names):
            let list = names.joined(separator: ", ")
            return "Unsupported URL parameter(s): \(list). Supported parameters: sslmode, sslrootcert, connect_timeout, host, port, dbname, user, password."
        }
    }
}

public enum PostgresUrlParser {
    private static let supportedSslModes: Set<String> = [
        "disable", "prefer", "require", "verify-ca", "verify-full"
    ]

    public static func parse(_ rawInput: String) throws -> ParsedPostgresUrl {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PostgresUrlParseError.emptyInput
        }
        if trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) {
            throw PostgresUrlParseError.invalidWhitespace
        }
        if trimmed.contains("#") {
            throw PostgresUrlParseError.fragmentNotSupported
        }

        guard let schemeSeparator = trimmed.range(of: "://") else {
            throw PostgresUrlParseError.missingScheme
        }

        let scheme = String(trimmed[..<schemeSeparator.lowerBound]).lowercased()
        guard scheme == "postgres" || scheme == "postgresql" else {
            throw PostgresUrlParseError.unsupportedScheme(scheme)
        }

        let afterScheme = String(trimmed[schemeSeparator.upperBound...])

        let authorityAndPath: String
        let rawQuery: String?
        if let qIndex = afterScheme.firstIndex(of: "?") {
            authorityAndPath = String(afterScheme[..<qIndex])
            let queryStart = afterScheme.index(after: qIndex)
            rawQuery = String(afterScheme[queryStart...])
            if let q = rawQuery, q.contains("@"), !authorityAndPath.contains("@") {
                throw PostgresUrlParseError.unescapedQuestionMarkInCredentials
            }
        } else {
            authorityAndPath = afterScheme
            rawQuery = nil
        }

        let rawAuthority: String
        let rawPath: String?
        if let slashIndex = authorityAndPath.firstIndex(of: "/") {
            rawAuthority = String(authorityAndPath[..<slashIndex])
            let pathStart = authorityAndPath.index(after: slashIndex)
            rawPath = String(authorityAndPath[pathStart...])
        } else {
            rawAuthority = authorityAndPath
            rawPath = nil
        }

        if let rawPath, rawPath.contains("/") {
            throw PostgresUrlParseError.malformedDatabasePath
        }

        let pathDatabase: String?
        if let rawPath, !rawPath.isEmpty {
            pathDatabase = try decodeComponent(rawPath, component: "database name")
        } else {
            pathDatabase = nil
        }

        // Parse userinfo@host:port
        let atParts = rawAuthority.split(separator: "@", omittingEmptySubsequences: false)
        let rawUserInfo: String?
        let rawHostPort: String
        if atParts.count > 2 {
            throw PostgresUrlParseError.multipleAtSignsInAuthority
        } else if atParts.count == 2 {
            let userInfoStr = String(atParts[0])
            if userInfoStr.isEmpty {
                throw PostgresUrlParseError.emptyUserInfo
            }
            rawUserInfo = userInfoStr
            rawHostPort = String(atParts[1])
        } else {
            rawUserInfo = nil
            rawHostPort = rawAuthority
        }

        var authorityUser: String? = nil
        var authorityPassword: String? = nil
        if let rawUserInfo {
            if let colonIdx = rawUserInfo.firstIndex(of: ":") {
                let rawUser = String(rawUserInfo[..<colonIdx])
                guard !rawUser.isEmpty else {
                    throw PostgresUrlParseError.missingUsername
                }
                let passStart = rawUserInfo.index(after: colonIdx)
                let rawPass = String(rawUserInfo[passStart...])
                authorityUser = try decodeComponent(rawUser, component: "username")
                authorityPassword = try decodeComponent(rawPass, component: "password")
            } else {
                authorityUser = try decodeComponent(rawUserInfo, component: "username")
            }
        }

        let (authorityHost, authorityPort) = try parseHostPort(rawHostPort)

        // Parse query parameters
        var queryHost: String? = nil
        var queryPort: UInt16? = nil
        var queryDbName: String? = nil
        var queryUser: String? = nil
        var queryPassword: String? = nil
        var sslMode: String? = nil
        var sslRootCert: String? = nil
        var sawSslRootCertSystem = false
        var timeoutSeconds: UInt32? = nil
        var unsupported: [String] = []

        if let rawQuery, !rawQuery.isEmpty {
            let pairs = rawQuery.split(separator: "&", omittingEmptySubsequences: false)
            for rawPair in pairs {
                let pairStr = String(rawPair)
                if pairStr.isEmpty {
                    continue
                }
                guard let eqIdx = pairStr.firstIndex(of: "=") else {
                    let badName = (try? decodeComponent(pairStr, component: "query parameter")) ?? "parameter"
                    throw PostgresUrlParseError.malformedQueryParameter(badName)
                }
                let rawKey = String(pairStr[..<eqIdx])
                let valStart = pairStr.index(after: eqIdx)
                let rawVal = String(pairStr[valStart...])

                let key = try decodeComponent(rawKey, component: "query parameter name").lowercased()
                let value = try decodeComponent(rawVal, component: "parameter '\(key)'")

                switch key {
                case "host":
                    if value.contains(",") {
                        throw PostgresUrlParseError.multiHostNotSupported
                    }
                    if let ah = authorityHost, ah.caseInsensitiveCompare(value) != .orderedSame {
                        throw PostgresUrlParseError.conflictingParameter("host")
                    }
                    if let qh = queryHost, qh.caseInsensitiveCompare(value) != .orderedSame {
                        throw PostgresUrlParseError.conflictingParameter("host")
                    }
                    queryHost = value.isEmpty ? nil : value

                case "port":
                    let parsedPort = try parsePortString(value)
                    if let ap = authorityPort, ap != parsedPort {
                        throw PostgresUrlParseError.conflictingParameter("port")
                    }
                    if let qp = queryPort, qp != parsedPort {
                        throw PostgresUrlParseError.conflictingParameter("port")
                    }
                    queryPort = parsedPort

                case "dbname":
                    if value.isEmpty {
                        throw PostgresUrlParseError.malformedDatabasePath
                    }
                    if let pd = pathDatabase, pd != value {
                        throw PostgresUrlParseError.conflictingParameter("dbname")
                    }
                    if let qd = queryDbName, qd != value {
                        throw PostgresUrlParseError.conflictingParameter("dbname")
                    }
                    queryDbName = value

                case "user":
                    if value.isEmpty {
                        throw PostgresUrlParseError.missingUsername
                    }
                    if let au = authorityUser, au != value {
                        throw PostgresUrlParseError.conflictingParameter("user")
                    }
                    if let qu = queryUser, qu != value {
                        throw PostgresUrlParseError.conflictingParameter("user")
                    }
                    queryUser = value

                case "password":
                    if let ap = authorityPassword, ap != value {
                        throw PostgresUrlParseError.conflictingParameter("password")
                    }
                    if let qp = queryPassword, qp != value {
                        throw PostgresUrlParseError.conflictingParameter("password")
                    }
                    queryPassword = value

                case "sslmode":
                    let normalized = value.lowercased()
                    guard supportedSslModes.contains(normalized) else {
                        throw PostgresUrlParseError.unsupportedSslMode(value)
                    }
                    if let existing = sslMode, existing != normalized {
                        throw PostgresUrlParseError.conflictingParameter("sslmode")
                    }
                    sslMode = normalized

                case "sslrootcert":
                    let trimmedCert = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmedCert.isEmpty {
                        throw PostgresUrlParseError.invalidSslRootCert("Parameter 'sslrootcert' cannot be empty.")
                    }
                    if trimmedCert.caseInsensitiveCompare("system") == .orderedSame {
                        if sslRootCert != nil {
                            throw PostgresUrlParseError.conflictingParameter("sslrootcert")
                        }
                        sawSslRootCertSystem = true
                        sslRootCert = nil
                    } else {
                        if sawSslRootCertSystem || (sslRootCert != nil && sslRootCert != trimmedCert) {
                            throw PostgresUrlParseError.conflictingParameter("sslrootcert")
                        }
                        sslRootCert = trimmedCert
                    }

                case "connect_timeout":
                    guard let secs = UInt32(value), secs >= 1, secs <= 300 else {
                        throw PostgresUrlParseError.invalidConnectTimeout(
                            "Invalid connect_timeout '\(value)'. Expected integer seconds between 1 and 300."
                        )
                    }
                    if let existing = timeoutSeconds, existing != secs {
                        throw PostgresUrlParseError.conflictingParameter("connect_timeout")
                    }
                    timeoutSeconds = secs

                default:
                    if !unsupported.contains(key) {
                        unsupported.append(key)
                    }
                }
            }
        }

        if !unsupported.isEmpty {
            throw PostgresUrlParseError.unsupportedParameters(unsupported)
        }

        if sslRootCert != nil || sawSslRootCertSystem {
            let effectiveMode = sslMode ?? "prefer"
            if effectiveMode != "verify-ca" && effectiveMode != "verify-full" {
                throw PostgresUrlParseError.invalidSslRootCert(
                    "Parameter 'sslrootcert' requires sslmode=verify-ca or sslmode=verify-full (currently '\(effectiveMode)')."
                )
            }
        }

        guard let finalHost = authorityHost ?? queryHost, !finalHost.isEmpty else {
            throw PostgresUrlParseError.missingHost
        }

        return ParsedPostgresUrl(
            host: finalHost,
            port: authorityPort ?? queryPort ?? 5432,
            database: pathDatabase ?? queryDbName ?? "postgres",
            user: authorityUser ?? queryUser ?? "postgres",
            password: authorityPassword ?? queryPassword,
            sslMode: sslMode,
            sslRootCert: sslRootCert,
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func decodeComponent(_ raw: String, component: String) throws -> String {
        guard let decoded = raw.removingPercentEncoding else {
            throw PostgresUrlParseError.invalidPercentEncoding(component: component)
        }
        if decoded.contains("\0") {
            throw PostgresUrlParseError.nullCharacterNotAllowed(component: component)
        }
        return decoded
    }

    private static func parsePortString(_ raw: String) throws -> UInt16 {
        guard !raw.isEmpty,
              raw.allSatisfy(\.isASCII),
              raw.allSatisfy(\.isNumber),
              let value = UInt16(raw),
              value >= 1 else {
            throw PostgresUrlParseError.invalidPort(raw)
        }
        return value
    }

    private static func parseHostPort(_ rawHostPort: String) throws -> (String?, UInt16?) {
        if rawHostPort.isEmpty {
            return (nil, nil)
        }
        if rawHostPort.contains(",") {
            throw PostgresUrlParseError.multiHostNotSupported
        }

        if rawHostPort.hasPrefix("[") {
            guard let closeIdx = rawHostPort.firstIndex(of: "]") else {
                throw PostgresUrlParseError.malformedIPv6("Malformed IPv6 host: missing closing ']'.")
            }
            let innerStart = rawHostPort.index(after: rawHostPort.startIndex)
            let rawInner = String(rawHostPort[innerStart..<closeIdx])
            let decodedHost = try decodeComponent(rawInner, component: "IPv6 host")
            guard !decodedHost.isEmpty, decodedHost.contains(":") else {
                throw PostgresUrlParseError.malformedIPv6("Malformed IPv6 host inside '[' and ']'.")
            }
            if decodedHost.contains("[") || decodedHost.contains("]") {
                throw PostgresUrlParseError.malformedIPv6("Malformed IPv6 host: unexpected bracket inside address.")
            }

            let afterCloseIdx = rawHostPort.index(after: closeIdx)
            let remainder = String(rawHostPort[afterCloseIdx...])
            if remainder.isEmpty {
                return (decodedHost, nil)
            }
            guard remainder.hasPrefix(":") else {
                throw PostgresUrlParseError.malformedIPv6("Malformed host after IPv6 address '\(remainder)'.")
            }
            let portStr = String(remainder.dropFirst())
            let port = try parsePortString(portStr)
            return (decodedHost, port)
        }

        if rawHostPort.contains("[") || rawHostPort.contains("]") {
            throw PostgresUrlParseError.malformedIPv6("Malformed host: unexpected '[' or ']'.")
        }

        let colonCount = rawHostPort.filter { $0 == ":" }.count
        if colonCount >= 2 {
            throw PostgresUrlParseError.malformedIPv6("IPv6 hosts in URLs must be enclosed in brackets, e.g. [::1]:5432.")
        }

        if colonCount == 1, let colonIdx = rawHostPort.firstIndex(of: ":") {
            let rawHost = String(rawHostPort[..<colonIdx])
            let portStart = rawHostPort.index(after: colonIdx)
            let portStr = String(rawHostPort[portStart...])
            let port = try parsePortString(portStr)
            let decodedHost = try decodeComponent(rawHost, component: "host")
            return (decodedHost.isEmpty ? nil : decodedHost, port)
        }

        let decodedHost = try decodeComponent(rawHostPort, component: "host")
        return (decodedHost.isEmpty ? nil : decodedHost, nil)
    }
}
