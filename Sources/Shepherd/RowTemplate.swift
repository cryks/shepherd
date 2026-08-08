// Template language for user-customizable agent rows and notifications.
// The grammar is intentionally total: it has no escape syntax and no error
// path, so an unmatched `{`, `[`, `}` or `]` is literal text rather than a
// failure the user has to diagnose.
//
//   {name}      variable, name characters [A-Za-z0-9_.]
//   {a|b|c}     first alternative that resolves non-empty
//   [ ... ]     renders only when a variable inside it resolved non-empty;
//               a group with no variable is literal text. Groups nest.

import Foundation

enum TemplateRun: Equatable, Sendable {
    case text(String)
    case icon(agent: String)
}

enum TemplateValue: Equatable, Sendable {
    case text(String)
    case icon(agent: String)
}

struct RowTemplate: Equatable, Sendable {
    // Only the source is persisted; the node tree is derived from it, so
    // equality on the source alone is complete.
    let source: String

    private let nodes: [Node]

    init(_ source: String) {
        self.source = source
        var index = 0
        nodes = Self.parse(Array(source), from: &index, insideGroup: false).nodes
    }

    static func == (lhs: RowTemplate, rhs: RowTemplate) -> Bool {
        lhs.source == rhs.source
    }

    // Feeds the settings pane's warning about unknown names, so the empty name
    // from `{}` is left out: no user meant to write it.
    var variableNames: [String] {
        var names: [String] = []
        Self.collectVariableNames(nodes, into: &names)
        return names
    }

    func render(_ resolve: (String) -> TemplateValue?) -> [TemplateRun] {
        Self.trimmingOuterWhitespace(Self.evaluate(nodes, resolve).runs)
    }

    // Notifications carry no images, so icon runs drop out of the string here
    // while still counting as non-empty for `{a|b}` and `[...]`.
    func renderText(_ resolve: (String) -> TemplateValue?) -> String {
        var text = ""
        for case .text(let part) in render(resolve) { text += part }
        return Self.trimmingTrailingWhitespace(Self.trimmingLeadingWhitespace(text))
    }

    // MARK: - Node tree

    private enum Node: Equatable, Sendable {
        case text(String)
        case variable([String])
        case group([Node])
    }

    private static func parse(
        _ characters: [Character],
        from index: inout Int,
        insideGroup: Bool
    ) -> (nodes: [Node], closed: Bool) {
        var nodes: [Node] = []
        var literal = ""

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            nodes.append(.text(literal))
            literal = ""
        }

        while index < characters.count {
            let character = characters[index]
            if character == "]", insideGroup {
                index += 1
                flushLiteral()
                return (nodes, true)
            }
            if character == "[" {
                var inner = index + 1
                let group = parse(characters, from: &inner, insideGroup: true)
                index = inner
                if group.closed {
                    flushLiteral()
                    nodes.append(.group(group.nodes))
                } else {
                    // The inner parse hit the end of the source, so it already
                    // produced exactly the nodes this level would produce.
                    // Adopting them avoids re-parsing the rest of the source.
                    literal.append("[")
                    flushLiteral()
                    nodes.append(contentsOf: group.nodes)
                }
                continue
            }
            if character == "{", let variable = scanVariable(characters, from: index) {
                flushLiteral()
                nodes.append(.variable(variable.names))
                index = variable.next
                continue
            }
            literal.append(character)
            index += 1
        }
        flushLiteral()
        return (nodes, false)
    }

    // nil leaves the `{` to be consumed as literal text.
    private static func scanVariable(
        _ characters: [Character],
        from index: Int
    ) -> (names: [String], next: Int)? {
        var cursor = index + 1
        var content = ""
        while cursor < characters.count,
              isNameCharacter(characters[cursor]) || characters[cursor] == "|" {
            content.append(characters[cursor])
            cursor += 1
        }
        guard cursor < characters.count, characters[cursor] == "}" else { return nil }
        // Keeping empty alternatives makes `{a|}` and `{}` stay one variable
        // that renders empty, instead of collapsing to no variable at all.
        let names = content
            .split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init)
        return (names, cursor + 1)
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || character == "_" || character == "."
    }

    private static func collectVariableNames(_ nodes: [Node], into names: inout [String]) {
        for node in nodes {
            switch node {
            case .text:
                continue
            case .variable(let alternatives):
                names.append(contentsOf: alternatives.filter { !$0.isEmpty })
            case .group(let children):
                collectVariableNames(children, into: &names)
            }
        }
    }

    // MARK: - Rendering

    // A group propagates its counts to the parent whether or not it rendered,
    // so an outer group is dropped when every variable below it stayed empty.
    private static func evaluate(
        _ nodes: [Node],
        _ resolve: (String) -> TemplateValue?
    ) -> (runs: [TemplateRun], variables: Int, resolved: Int) {
        var runs: [TemplateRun] = []
        var variables = 0
        var resolved = 0
        for node in nodes {
            switch node {
            case .text(let text):
                append(.text(text), to: &runs)
            case .variable(let alternatives):
                variables += 1
                guard let value = firstNonEmpty(alternatives, resolve) else { continue }
                resolved += 1
                switch value {
                case .text(let text): append(.text(text), to: &runs)
                case .icon(let agent): append(.icon(agent: agent), to: &runs)
                }
            case .group(let children):
                let group = evaluate(children, resolve)
                variables += group.variables
                resolved += group.resolved
                // A group with no variable is plain literal text: it renders.
                guard group.variables == 0 || group.resolved > 0 else { continue }
                for run in group.runs { append(run, to: &runs) }
            }
        }
        return (runs, variables, resolved)
    }

    private static func firstNonEmpty(
        _ alternatives: [String],
        _ resolve: (String) -> TemplateValue?
    ) -> TemplateValue? {
        for name in alternatives {
            switch resolve(name) {
            case .text(let text) where !text.isEmpty: return .text(text)
            case .icon(let agent): return .icon(agent: agent)
            default: continue
            }
        }
        return nil
    }

    private static func append(_ run: TemplateRun, to runs: inout [TemplateRun]) {
        guard case .text(let text) = run else {
            runs.append(run)
            return
        }
        guard !text.isEmpty else { return }
        if case .text(let previous)? = runs.last {
            runs[runs.index(before: runs.endIndex)] = .text(previous + text)
        } else {
            runs.append(run)
        }
    }

    // Only the outer edges are trimmed: interior whitespace is how separators
    // are written (`[ · {x}]`), and an outermost icon run shields the text
    // beside it.
    private static func trimmingOuterWhitespace(_ runs: [TemplateRun]) -> [TemplateRun] {
        var runs = runs
        if case .text(let text)? = runs.first {
            let trimmed = trimmingLeadingWhitespace(text)
            if trimmed.isEmpty {
                runs.removeFirst()
            } else {
                runs[runs.startIndex] = .text(trimmed)
            }
        }
        if case .text(let text)? = runs.last {
            let trimmed = trimmingTrailingWhitespace(text)
            if trimmed.isEmpty {
                runs.removeLast()
            } else {
                runs[runs.index(before: runs.endIndex)] = .text(trimmed)
            }
        }
        return runs
    }

    private static func trimmingLeadingWhitespace(_ text: String) -> String {
        String(text.drop(while: \.isWhitespace))
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var text = text
        while let last = text.last, last.isWhitespace { text.removeLast() }
        return text
    }
}

extension RowTemplate: Codable {
    // Coded as a bare string so a stored layout stays hand-editable.
    init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(source)
    }
}

// The view layer owns the font and color each name stands for. `status` is the
// only one that follows the pane's AgentStatus color, and drops it while a menu
// row is hovered.
enum RowTextStyle: String, Codable, CaseIterable, Sendable {
    case heading
    case body
    case subdued
    case monospace
    case status

    // A style added by a newer build must not fail the whole decode and throw
    // away every customization, so an unknown name degrades to `body`.
    init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = RowTextStyle(rawValue: rawValue) ?? .body
    }
}
