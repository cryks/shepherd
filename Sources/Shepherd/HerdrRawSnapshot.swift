import Foundation

// Records stay exactly as herdr sent them, so the template layer can address
// any field by its wire name. Enrichment belongs to the caller: AgentSnapshot
// adds `branch` to each workspace record from worktree.list.
struct HerdrRawSnapshot: Equatable, Sendable {
    var agents: [String: JSONValue]
    var workspaces: [String: JSONValue]
    var tabs: [String: JSONValue]
    // Kept so that a failed typed decode of the same line can still name the
    // server's protocol. nil when the response carried none.
    var serverProtocol: Int? = nil

    static let empty = HerdrRawSnapshot(agents: [:], workspaces: [:], tabs: [:])

    // A plain JSONDecoder, not makeDecoder(): .convertFromSnakeCase would
    // camelCase the dynamic keys of this tree, while the template language
    // addresses fields by their snake_case wire names. This is why the same
    // response line is decoded twice.
    //
    // Shapes that do not match yield empty maps and elements without a string
    // id are dropped, so a protocol addition cannot fail a poll the typed
    // decode accepted. Only a line that is not JSON at all throws.
    static func decode(responseLine: Data) throws -> HerdrRawSnapshot {
        let root = try JSONDecoder().decode(JSONValue.self, from: responseLine)
        let snapshot = root["result"]?["snapshot"]
        var serverProtocol: Int?
        if case .int(let value)? = snapshot?["protocol"] {
            serverProtocol = Int(exactly: value)
        }
        return HerdrRawSnapshot(
            agents: index(snapshot?["agents"], by: "pane_id"),
            workspaces: index(snapshot?["workspaces"], by: "workspace_id"),
            tabs: index(snapshot?["tabs"], by: "tab_id"),
            serverProtocol: serverProtocol
        )
    }

    private static func index(_ array: JSONValue?, by idKey: String) -> [String: JSONValue] {
        guard case .array(let elements)? = array else { return [:] }
        var records: [String: JSONValue] = [:]
        records.reserveCapacity(elements.count)
        for element in elements {
            guard case .string(let id)? = element[idKey] else { continue }
            records[id] = element
        }
        return records
    }
}
