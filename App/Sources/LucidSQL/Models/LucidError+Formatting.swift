import Foundation
import LucidSQLBridge

extension LucidError {
    public var userFacingMessage: String {
        switch self {
        case .ConnectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .AuthenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .QueryCancelled:
            return "Query was cancelled by user."
        case .QueryTimedOut(let durationMs):
            return "Query timed out after \(durationMs) ms."
        case .ReadOnlyViolation(let attemptedOperation):
            return "Read-only restriction: \(attemptedOperation)"
        case .ConflictDetected(let tableName, let primaryKeyValues):
            let keys = primaryKeyValues.joined(separator: ", ")
            return "Conflict detected in \(tableName): row (\(keys)) was modified or deleted by another session. All staged changes were rolled back."
        case .MissingPrimaryKey(let tableName):
            return "Table \(tableName) has no primary key and cannot be edited safely."
        case .UncertainCommitOutcome(let message):
            return "Commit outcome uncertain: \(message)"
        case .DatabaseError(let code, let message, let detail):
            var formatted = code.isEmpty ? message : "SQLSTATE \(code): \(message)"
            if let detail, !detail.isEmpty, !message.contains(detail) {
                formatted += " (Detail: \(detail))"
            }
            return formatted
        }
    }
}

extension Error {
    public var userFacingMessage: String {
        if let lucidError = self as? LucidError {
            return lucidError.userFacingMessage
        }
        return localizedDescription
    }
}
