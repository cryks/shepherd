// Templates must address herdr records under the exact keys herdr puts on the
// wire. The typed models cannot carry them: they decode through
// makeDecoder(), whose .convertFromSnakeCase rewrites every key of a container
// with dynamic coding keys, and an arbitrary JSON tree needs such a container.
// Values of this type are therefore decoded only with a plain JSONDecoder,
// which HerdrRawSnapshot does in a second pass.

import Foundation

enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    // Pane revisions exceed 2^53, which no Double can represent, so decoding
    // tries this case before `double`.
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
    // A wrong assumption about the record shape reads as absent, not as an
    // error.
    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    func value(at path: some Sequence<Substring>) -> JSONValue? {
        var current: JSONValue? = self
        for component in path {
            guard let node = current else { return nil }
            current = node[String(component)]
        }
        return current
    }

    // Cases with no single-line form return nil, which the template layer
    // renders as empty instead of failing.
    var templateText: String? {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            // Int64(exactly:) accepts only integral values inside its range,
            // which drops the trailing ".0" from whole numbers and lets 3.5
            // and larger magnitudes keep the shortest round-trip form.
            if let integral = Int64(exactly: value) { return String(integral) }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null, .array, .object:
            return nil
        }
    }
}
