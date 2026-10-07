import Foundation

/// A JSON value whose objects keep their key order, parsed leniently: like HomeClerk's config files
/// have always been read, // and /* */ comments and trailing commas are allowed. The response schema relies on order — the
/// model writes "summary" before "documents" because it comes first — and Foundation's
/// dictionaries don't keep it.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    /// The value for `key` when this is an object.
    public subscript(key: String) -> JSONValue? {
        guard case let .object(pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    /// Compact JSON text, keys in order.
    public var serialized: String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .number(n):
            out += n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case let .string(s): JSONValue.writeString(s, to: &out)
        case let .array(items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(to: &out)
            }
            out += "]"
        case let .object(pairs):
            out += "{"
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += "," }
                JSONValue.writeString(pair.key, to: &out)
                out += ":"
                pair.value.write(to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

// MARK: - Parsing

extension JSONValue {
    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Parses JSON text, keeping object keys in order.
    public init(parsing text: String) throws {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        self = try parser.parseDocument()
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var i = 0
        var depth = 0
        static let maxDepth = 256

        mutating func parseDocument() throws -> JSONValue {
            let value = try parseValue()
            skipWhitespace()
            guard i == scalars.count else { throw error("unexpected text after the JSON value") }
            return value
        }

        mutating func parseValue() throws -> JSONValue {
            skipWhitespace()
            guard i < scalars.count else { throw error("unexpected end of input") }
            switch scalars[i] {
            case "{", "[":
                depth += 1
                defer { depth -= 1 }
                guard depth <= Self.maxDepth else { throw error("nested too deeply") }
                return scalars[i] == "{" ? try parseObject() : try parseArray()
            case "\"": return .string(try parseString())
            case "t": try expect("true"); return .bool(true)
            case "f": try expect("false"); return .bool(false)
            case "n": try expect("null"); return .null
            default: return .number(try parseNumber())
            }
        }

        mutating func parseObject() throws -> JSONValue {
            i += 1
            var pairs: [(key: String, value: JSONValue)] = []
            skipWhitespace()
            if peek("}") { i += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                if peek("}") { i += 1; return .object(pairs) }   // trailing comma
                guard peek("\"") else { throw error("expected a key") }
                let key = try parseString()
                skipWhitespace()
                guard peek(":") else { throw error("expected ':'") }
                i += 1
                pairs.append((key, try parseValue()))
                skipWhitespace()
                if peek(",") { i += 1; continue }
                if peek("}") { i += 1; return .object(pairs) }
                throw error("expected ',' or '}'")
            }
        }

        mutating func parseArray() throws -> JSONValue {
            i += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if peek("]") { i += 1; return .array(items) }
            while true {
                skipWhitespace()
                if peek("]") { i += 1; return .array(items) }   // trailing comma
                items.append(try parseValue())
                skipWhitespace()
                if peek(",") { i += 1; continue }
                if peek("]") { i += 1; return .array(items) }
                throw error("expected ',' or ']'")
            }
        }

        mutating func parseString() throws -> String {
            i += 1
            var out = String.UnicodeScalarView()
            while i < scalars.count {
                let c = scalars[i]
                i += 1
                switch c {
                case "\"": return String(out)
                case "\\":
                    guard i < scalars.count else { break }
                    let e = scalars[i]
                    i += 1
                    switch e {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        var code = try hex4()
                        // A surrogate pair encodes one scalar outside the Basic Multilingual Plane
                        if (0xD800...0xDBFF).contains(code), peek("\\"), i + 1 < scalars.count, scalars[i + 1] == "u" {
                            i += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        out.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default: throw error("invalid escape")
                    }
                default: out.append(c)
                }
            }
            throw error("unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= scalars.count,
                  let code = UInt32(String(String.UnicodeScalarView(scalars[i..<i + 4])), radix: 16)
            else { throw error("invalid \\u escape") }
            i += 4
            return code
        }

        mutating func parseNumber() throws -> Double {
            let start = i
            while i < scalars.count, "+-0123456789.eE".unicodeScalars.contains(scalars[i]) { i += 1 }
            guard let n = Double(String(String.UnicodeScalarView(scalars[start..<i]))) else {
                throw error("invalid number")
            }
            return n
        }

        mutating func expect(_ word: String) throws {
            for c in word.unicodeScalars {
                guard i < scalars.count, scalars[i] == c else { throw error("invalid literal") }
                i += 1
            }
        }

        func peek(_ c: Unicode.Scalar) -> Bool { i < scalars.count && scalars[i] == c }

        /// Skips whitespace and comments.
        mutating func skipWhitespace() {
            while i < scalars.count {
                if [" ", "\n", "\r", "\t"].contains(scalars[i]) {
                    i += 1
                } else if peek("/"), i + 1 < scalars.count, scalars[i + 1] == "/" {
                    while i < scalars.count, scalars[i] != "\n" { i += 1 }
                } else if peek("/"), i + 1 < scalars.count, scalars[i + 1] == "*" {
                    i += 2
                    while i + 1 < scalars.count, !(scalars[i] == "*" && scalars[i + 1] == "/") { i += 1 }
                    i += 2
                } else {
                    return
                }
            }
        }

        func error(_ message: String) -> ParseError { ParseError(description: "\(message) at offset \(i)") }
    }
}

// MARK: - Reading values

extension JSONValue {
    public var stringValue: String? { if case let .string(s) = self { s } else { nil } }
    public var doubleValue: Double? { if case let .number(n) = self { n } else { nil } }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { a } else { nil } }
    public var objectPairs: [(key: String, value: JSONValue)]? { if case let .object(o) = self { o } else { nil } }

    /// Strings in an array, skipping anything else; nil when this isn't an array.
    var stringArray: [String]? { arrayValue?.compactMap(\.stringValue) }
}

extension JSONValue {
    /// Indented JSON, keys in order.
    func pretty(indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case let .object(pairs) where !pairs.isEmpty:
            return "{\n" + pairs.map { "\(inner)\(JSONValue.string($0.key).serialized): \($0.value.pretty(indent: inner))" }
                .joined(separator: ",\n") + "\n\(indent)}"
        case let .array(items) where !items.isEmpty:
            return "[\n" + items.map { inner + $0.pretty(indent: inner) }.joined(separator: ",\n") + "\n\(indent)]"
        default:
            return serialized
        }
    }
}
