// A verbatim JSON tree, used to expose herdr records to the row and
// notification templates under the exact keys herdr puts on the wire.
//
// The typed models in Models.swift cannot serve that purpose: they decode
// through makeDecoder(), whose keyDecodingStrategy = .convertFromSnakeCase
// rewrites every key of any container with dynamic coding keys — and an
// arbitrary JSON tree can only be decoded through such a container. So
// `terminal_title_stripped` would arrive as `terminalTitleStripped` and
// `{herdr.agent.terminal_title_stripped}` would never resolve. Values of this
// type are therefore only decoded with a plain JSONDecoder; HerdrRawSnapshot
// owns that second pass.
//
// Rendering is total: values with no single-line text form (null, arrays,
// objects) yield nil from templateText, which the template layer treats as
// empty rather than as an error.

import Foundation

/// One JSON value exactly as herdr sent it.
enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    /// Whole numbers keep 64-bit precision. Pane revisions exceed 2^53
    /// (HerdrProtocolTests pins 9007199254740993), which no Double can
    /// represent, so decoding tries this case before `double`.
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "value is not JSON"
            )
        }
    }
}

extension JSONValue {
    /// Member of an object. nil for a missing key and for every non-object case,
    /// so a wrong assumption about the record shape reads as absent.
    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    /// Walks a dotted path (`agent_session.value` split on ".") from this value.
    /// Returns nil as soon as one component is missing or lands on a non-object.
    /// An empty path returns self.
    func value(at path: some Sequence<Substring>) -> JSONValue? {
        var current: JSONValue? = self
        for component in path {
            guard let node = current else { return nil }
            current = node[String(component)]
        }
        return current
    }

    /// Single-line text form used when a variable resolves to this value.
    /// Strings pass through; integers print base 10; doubles print their
    /// shortest round-trip form, without a trailing ".0" when they are
    /// integral; bools print "true"/"false". null, arrays, and objects have no
    /// text form and return nil.
    var templateText: String? {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            // Int64(exactly:) accepts only integral values inside its range, so
            // ordinary whole numbers print as "3" while 3.5 and magnitudes past
            // Int64 fall through to Swift's shortest round-trip description.
            if let integral = Int64(exactly: value) { return String(integral) }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null, .array, .object:
            return nil
        }
    }
}
