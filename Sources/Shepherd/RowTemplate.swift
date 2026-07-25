// The template language behind user-customizable agent rows and notifications.
//
// Grammar, with no escape syntax:
//   {name}      variable; name characters are [A-Za-z0-9_.]
//   {a|b|c}     fallback: the first alternative that resolves non-empty
//   [ ... ]     group; renders only when at least one variable inside it
//               resolved non-empty. A group holding no variable is literal
//               text and always renders. Groups nest.
//   everything else is literal text
//
// Parsing and rendering are total: there is no error type and no throwing
// path. A `{` or `[` without its partner, a stray `}` or `]`, and any `{` not
// followed by name characters and `}` stay literal text. `{}` parses as a
// variable whose name is empty, which no resolver knows, so it renders empty —
// as does any name the resolver does not know.
//
// Whitespace inside a group is preserved verbatim, because that is how
// separators are written (`[ · {x}]`); the finished render has its leading and
// trailing whitespace trimmed.
//
// This layer knows nothing about herdr, fonts, or images: variables are opaque
// names the caller resolves, RowTextStyle is a name the view layer maps to a
// font, and an icon run carries only an agent id.

import Foundation

/// One resolved piece of a rendered template.
enum TemplateRun: Equatable, Sendable {
    case text(String)
    /// Brand mark for this agent id; the view layer resolves the asset and size.
    case icon(agent: String)
}

/// A value a variable can resolve to.
enum TemplateValue: Equatable, Sendable {
    /// The empty string counts as EMPTY: it does not satisfy a `{a|b}`
    /// alternative and does not make a `[...]` group render.
    case text(String)
    /// Always counts as non-empty. A resolver that has no asset for the agent
    /// returns nil or empty text instead.
    case icon(agent: String)
}

/// A parsed template. Parsing never fails.
struct RowTemplate: Equatable, Sendable {
    /// The template as the user wrote it. It is the only persisted form; the
    /// node tree is derived from it, which is why equality compares sources.
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

    /// Every variable name referenced, in source order, including fallback
    /// alternatives. The settings pane uses it to warn about names no resolver
    /// knows. The empty name produced by `{}` is left out — it is not a name a
    /// user could have meant.
    var variableNames: [String] {
        var names: [String] = []
        Self.collectVariableNames(nodes, into: &names)
        return names
    }

    /// Renders to runs. Adjacent text runs are coalesced, empty text produces
    /// no run, and the leading and trailing whitespace of the whole render is
    /// trimmed.
    ///
    /// - Parameter resolve: Value for a variable name. nil means the name is
    ///   unknown and is indistinguishable from `.text("")` in the result.
    func render(_ resolve: (String) -> TemplateValue?) -> [TemplateRun] {
        Self.trimmingOuterWhitespace(Self.evaluate(nodes, resolve).runs)
    }

    /// Text-only render: icon runs contribute nothing to the string, but still
    /// count as non-empty for `{a|b}` and `[...]`. Used by notifications, where
    /// the resolver already returns empty for image-only variables.
    func renderText(_ resolve: (String) -> TemplateValue?) -> String {
        var text = ""
        for case .text(let part) in render(resolve) { text += part }
        return Self.trimmingTrailingWhitespace(Self.trimmingLeadingWhitespace(text))
    }

    // MARK: - Node tree

    private enum Node: Equatable, Sendable {
        case text(String)
        /// Fallback alternatives in source order; a plain `{name}` holds one.
        case variable([String])
        case group([Node])
    }

    /// Parses until the end of the source, or until the `]` that closes the
    /// group the caller opened. `closed` reports whether that `]` was found, so
    /// the caller can fall back to treating its `[` as literal text.
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
                    // Unclosed: the bracket becomes literal text. The inner
                    // parse ran to the end of the source and, having found no
                    // `]`, produced exactly the nodes this level would have, so
                    // they are adopted instead of re-parsed.
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

    /// Reads `{a|b}` starting at the `{`. Returns nil when the braces hold
    /// anything but name characters and `|`, or when the `}` is missing, which
    /// leaves the `{` to be consumed as literal text.
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
        // Empty alternatives are kept so `{a|}` and `{}` stay one variable with
        // a name no resolver knows, rather than collapsing to nothing.
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

    /// Renders a node list and reports how many variables it contains and how
    /// many of them resolved non-empty. A group decides on its own counts, and
    /// propagates them to its parent whether or not it rendered, so an outer
    /// group is discarded when the only variables below it stayed empty.
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

    /// Trims the render's outer whitespace only. Interior whitespace, including
    /// a separator a group contributed, is untouched, and a leading or trailing
    /// icon run shields the text next to it from trimming.
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
    /// Coded as its source string, so a stored layout reads as plain templates.
    init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(source)
    }
}

/// Preset appearance of one side of a row line. The view layer owns the font
/// and color each name stands for; `status` is the one that follows the pane's
/// AgentStatus color and drops it while a menu row is hovered.
enum RowTextStyle: String, Codable, CaseIterable, Sendable {
    case heading
    case body
    case subdued
    case monospace
    case status

    /// A name this build does not know reads as `body`, so a layout stored by a
    /// newer version loses one line's appearance instead of failing to decode
    /// and dropping every customization.
    init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = RowTextStyle(rawValue: rawValue) ?? .body
    }
}
