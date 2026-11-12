import Foundation
import LucidSQLBridge

extension CellValue {
    public var displayString: String {
        switch self {
        case .null:
            return "NULL"
        case .text(let s):
            return s
        case .boolean(let b):
            return b ? "true" : "false"
        case .integer(let i):
            return String(i)
        case .decimal(let d):
            return d
        case .float(let f):
            return String(f)
        case .timestampWithTimeZone(let tz):
            return tz
        case .timestampWithoutTimeZone(let naive):
            return naive
        case .date(let d):
            return d
        case .time(let t):
            return t
        case .uuid(let u):
            return u
        case .binaryHex(let h):
            return h
        case .json(let j):
            return j
        case .unsupported(let typeOrReason):
            return "Unsupported (\(typeOrReason))"
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var isUnsupported: Bool {
        if case .unsupported = self { return true }
        return false
    }

    /// Returns the raw string only when this value is an explicit `.text` payload (never a display placeholder).
    public var rawTextValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    /// Returns text suitable for initializing an in-place editor, or nil for non-editable `.unsupported` values.
    public var editableString: String? {
        switch self {
        case .null:
            return ""
        case .unsupported:
            return nil
        default:
            return displayString
        }
    }
}
