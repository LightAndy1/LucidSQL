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
        case .unsupported(let raw):
            return raw
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
