// The herdr records of one session.snapshot kept verbatim, so the template
// layer can name any field herdr sends: `{herdr.agent.<path>}` reads an
// agents element, `{herdr.workspace.<path>}` a workspaces element, and
// `{herdr.tab.<path>}` a tabs element.
//
// The same response line is decoded twice: once into HerdrSessionSnapshot with
// makeDecoder() for the typed model, and once here with a plain JSONDecoder.
// The second pass exists because .convertFromSnakeCase would camelCase the keys
// of the dynamic-key containers a JSONValue tree is built from, and the
// template language addresses fields by their snake_case wire names.
//
// Records are stored as received. Enrichment belongs to the caller:
// AgentSnapshot writes the worktree.list branch into each workspace record
// under `branch`, which is what `{herdr.workspace.branch}` reads.

import Foundation

/// Verbatim per-record herdr JSON from one session.snapshot, keyed by record id.
struct HerdrRawSnapshot: Equatable, Sendable {
    /// Keyed by `pane_id`.
    var agents: [String: JSONValue]
    /// Keyed by `workspace_id`. This is the pane's own workspace record; the
    /// merging of linked worktrees into one display group happens above and
    /// never rewrites these records.
    var workspaces: [String: JSONValue]
    /// Keyed by `tab_id`.
    var tabs: [String: JSONValue]
    /// `snapshot.protocol` of the same response. nil when the response did not
    /// carry one. Read when the typed decode of the same line fails, so the
    /// resulting error can name the server's protocol.
    var serverProtocol: Int? = nil

    static let empty = HerdrRawSnapshot(agents: [:], workspaces: [:], tabs: [:])

    /// Decodes one whole `session.snapshot` RPC response line with default key
    /// decoding, so keys stay snake_case as the template language exposes them.
    ///
    /// Reads `result.snapshot.agents`, `.workspaces`, `.tabs`, and `.protocol`.
    /// A missing or differently shaped array yields an empty map, and an
    /// element without a string id is dropped, so a protocol addition can never
    /// fail a poll that the typed decode accepted. Throws DecodingError only
    /// when the line is not JSON at all.
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
