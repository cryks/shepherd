import Foundation

struct AgentExcerpt: Equatable {
    enum Kind: Equatable {
        case activity
        case attention
        case response
    }

    enum Confidence: Equatable {
        case medium
        case high
    }

    var text: String
    var kind: Kind
    var confidence: Confidence
    var screenRevision: UInt64
}

// Unsupported agents get nil instead of this state, so their rows keep the
// ordinary two-line layout.
enum AgentExcerptState: Equatable {
    case loading
    case available(AgentExcerpt)
    case empty
}

struct AgentExcerptInput: Equatable {
    // The caller brackets `agent.read` with two `agent.get` status reads; a
    // pair that differs means the screen was captured across a transition.
    var statusBeforeRead: AgentStatus
    var statusAfterRead: AgentStatus
    // Pane-lifecycle marker the caller derives from equal bracketing
    // `agent.get` revisions: protocol 19 does not relate `pane_read.revision`
    // to that value.
    var revision: UInt64
    // Plain text with ANSI control sequences already removed.
    var text: String
}

enum AgentExcerptUpdate: Equatable {
    case keep
    case replace(AgentExcerpt)
    case remove
}

// One machine per agent session. Replacing the session, changing the canonical
// agent, or removing the terminal must replace or discard the machine, or
// another conversation inherits this cache.
struct AgentExcerptMachine {
    private enum Grammar {
        case codex
        case claude

        init?(agentID: String) {
            switch agentID.lowercased() {
            case "codex":
                self = .codex
            case "claude", "claude-code":
                self = .claude
            default:
                return nil
            }
        }

        func latestResponse(in screen: ExcerptScreen) -> String? {
            switch self {
            case .codex:
                CodexExcerptExtractor.latestResponse(in: screen)
            case .claude:
                ClaudeExcerptExtractor.latestResponse(in: screen)
            }
        }

        func activity(in screen: ExcerptScreen) -> String? {
            switch self {
            case .codex:
                CodexExcerptExtractor.activity(in: screen)
            case .claude:
                ClaudeExcerptExtractor.activity(in: screen)
            }
        }

        func attention(in screen: ExcerptScreen) -> String? {
            switch self {
            case .codex:
                CodexExcerptExtractor.attention(in: screen)
            case .claude:
                ClaudeExcerptExtractor.attention(in: screen)
            }
        }

        func isSuppressed(_ screen: ExcerptScreen) -> Bool {
            switch self {
            case .codex:
                CodexExcerptExtractor.isSuppressed(screen)
            case .claude:
                ClaudeExcerptExtractor.isSuppressed(screen)
            }
        }
    }

    private let grammar: Grammar
    private var lastRevision: UInt64?
    private var pendingResponse: String?
    private var pendingResponseCount = 0
    private var acceptedResponse: AgentExcerpt?
    private(set) var excerpt: AgentExcerpt?
    // Set when a settled read proposed a changed message. The caller reads it
    // to schedule the confirming read now instead of at the next poll tick.
    private(set) var requiresVerificationRead = false

    init?(agentID: String) {
        guard let grammar = Grammar(agentID: agentID) else { return nil }
        self.grammar = grammar
    }

    // Read monitors call this before issuing an RPC, so an unsupported agent
    // never contributes screen text.
    static func supports(agentID: String) -> Bool {
        Grammar(agentID: agentID) != nil
    }

    mutating func ingest(_ input: AgentExcerptInput) -> AgentExcerptUpdate {
        guard input.statusBeforeRead == input.statusAfterRead else {
            cancelPendingVerification()
            return .keep
        }
        // Revisions only grow within one terminal lifecycle, so a regression
        // means the pane restarted and the cache belongs to a dead session.
        if let lastRevision, input.revision < lastRevision {
            resetLifecycle()
        }
        lastRevision = input.revision

        let screen = ExcerptScreen(input.text)
        if grammar.isSuppressed(screen) {
            cancelPendingVerification()
            return publish(acceptedResponse)
        }

        switch input.statusAfterRead {
        case .working:
            cancelPendingVerification()
            // A single observation is enough here so streamed prose reaches
            // the row while the agent is still writing it.
            if let text = grammar.latestResponse(in: screen) {
                acceptedResponse = AgentExcerpt(
                    text: text,
                    kind: .response,
                    confidence: .medium,
                    screenRevision: input.revision
                )
                return publish(acceptedResponse)
            }
            if acceptedResponse == nil,
               let text = grammar.activity(in: screen) {
                return publish(AgentExcerpt(
                    text: text,
                    kind: .activity,
                    confidence: .medium,
                    screenRevision: input.revision
                ))
            }
            return publish(acceptedResponse)

        case .blocked:
            cancelPendingVerification()
            guard let text = grammar.attention(in: screen) else {
                return publish(acceptedResponse)
            }
            return publish(AgentExcerpt(
                text: text,
                kind: .attention,
                confidence: .high,
                screenRevision: input.revision
            ))

        case .done, .idle:
            guard let text = grammar.latestResponse(in: screen),
                  text != acceptedResponse?.text else {
                cancelPendingVerification()
                return publish(acceptedResponse)
            }
            guard verify(text) else {
                return publish(acceptedResponse)
            }
            acceptedResponse = AgentExcerpt(
                text: text,
                kind: .response,
                confidence: .medium,
                screenRevision: input.revision
            )
            return publish(acceptedResponse)

        case .unknown:
            cancelPendingVerification()
            return publish(acceptedResponse)
        }
    }

    private mutating func cancelPendingVerification() {
        pendingResponse = nil
        pendingResponseCount = 0
        requiresVerificationRead = false
    }

    // A settled status stops further reads until the next status change, so a
    // screen captured mid-redraw would stay on display indefinitely. Two
    // consecutive settled reads of the same text rule that out.
    private mutating func verify(_ candidate: String) -> Bool {
        if pendingResponse == candidate {
            pendingResponseCount += 1
        } else {
            pendingResponse = candidate
            pendingResponseCount = 1
        }

        guard pendingResponseCount >= 2 else {
            requiresVerificationRead = true
            return false
        }
        cancelPendingVerification()
        return true
    }

    private mutating func resetLifecycle() {
        lastRevision = nil
        acceptedResponse = nil
        cancelPendingVerification()
        // `excerpt` stays until publish(_:) runs, which is what turns the reset
        // into the explicit remove/replace the caller has to apply.
    }

    private mutating func publish(_ next: AgentExcerpt?) -> AgentExcerptUpdate {
        let hasSameDisplayValue = sameDisplayValue(excerpt, next)
        excerpt = next
        if hasSameDisplayValue {
            return .keep
        }
        guard let next else { return .remove }
        return .replace(next)
    }

    private func sameDisplayValue(
        _ lhs: AgentExcerpt?,
        _ rhs: AgentExcerpt?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (.some(let lhs), .some(let rhs)):
            return lhs.text == rhs.text &&
                lhs.kind == rhs.kind &&
                lhs.confidence == rhs.confidence
        default:
            return false
        }
    }
}

// Herdr returns non-breaking spaces and pads rows to the terminal width. Only
// those are normalized: the grammars recognize wrapped prose and tool trees by
// leading indentation, which must survive.
struct ExcerptScreen {
    var lines: [String]

    init(_ text: String) {
        lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingTrailingWhitespace() }
    }
}

enum ExcerptText {
    static let maximumCharacters = 240

    static func normalized(_ lines: [String]) -> String? {
        let value = lines
            .flatMap { $0.split(whereSeparator: \.isWhitespace) }
            .joined(separator: " ")
        guard !value.isEmpty else { return nil }
        return value
    }

    static func compact(_ lines: [String]) -> String? {
        guard let value = normalized(lines) else { return nil }
        guard value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters - 1)) + "…"
    }

    static func isHorizontalRule(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard value.count >= 8 else { return false }
        let ruleCharacters = Set("─━═-_")
        return value.allSatisfy { ruleCharacters.contains($0) }
    }

    // Callers reach this only while Herdr reports blocked, so the same words
    // inside a finished response cannot be mistaken for a live form.
    //
    // The question sits above the form's first choice, but rules can split the
    // choice list: Claude puts its escape-hatch "Chat about this" row, itself
    // sometimes numbered, below a rule of its own. The walk therefore starts at
    // the bottom choice and crosses one rule at a time upwards.
    static func attentionPrompt(in screen: ExcerptScreen) -> String? {
        let lines = screen.lines
        let isChoice: (String) -> Bool = { line in
            var value = line.trimmingCharacters(in: .whitespaces)
            for marker in ["› ", "❯ "] where value.hasPrefix(marker) {
                value.removeFirst(marker.count)
            }
            let lowercased = value.lowercased()
            if lowercased == "yes" ||
                lowercased.hasPrefix("yes ") ||
                lowercased.hasPrefix("yes,") ||
                lowercased == "no" ||
                lowercased.hasPrefix("no ") ||
                lowercased.hasPrefix("no,") {
                return true
            }
            let digits = value.prefix(while: \.isNumber)
            guard !digits.isEmpty else { return false }
            return value.dropFirst(digits.count).hasPrefix(".")
        }
        let isHint: (String) -> Bool = { line in
            let value = line.lowercased()
            return value.contains("enter to select") ||
                value.contains("enter to submit") ||
                value.contains("enter to confirm") ||
                value.contains("esc to cancel")
        }

        guard let lastAnchor = lines.lastIndex(where: {
            isChoice($0) || isHint($0)
        }) else {
            return nil
        }
        let trailingNonEmptyLines = lines[lines.index(after: lastAnchor)...]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let hasOnlyNavigationChrome =
            trailingNonEmptyLines.count == 1 &&
            isNavigationHint(trailingNonEmptyLines[0])
        guard trailingNonEmptyLines.isEmpty ||
                hasOnlyNavigationChrome else { return nil }

        var anchor = lines[...lastAnchor].lastIndex(where: isChoice)
        while let choiceAnchor = anchor {
            // A hint line closes an already-answered form, so it bounds the
            // region like a rule does. Some CLIs stack two forms with no rule
            // between them.
            let boundaryIndex = lines[..<choiceAnchor].lastIndex(where: {
                isHorizontalRule($0) || isHint($0)
            })
            let startIndex = boundaryIndex
                .map { lines.index(after: $0) } ?? lines.startIndex
            guard let choiceIndex = lines[startIndex...choiceAnchor]
                .firstIndex(where: isChoice)
            else {
                return nil
            }
            if let question = question(in: lines[startIndex..<choiceIndex]) {
                return question
            }
            guard let boundaryIndex,
                  isHorizontalRule(lines[boundaryIndex]) else {
                return nil
            }
            anchor = lines[..<boundaryIndex].lastIndex(where: isChoice)
        }
        return nil
    }

    // Selection is positional, not lexical: prompts are free-form text with no
    // required punctuation, so a "?" does not favor a candidate. Every supported
    // form renders the question last before the choices. A "Question N/M"
    // header wins over that rule because a form without a leading rule leaves
    // the region reaching to the top of the screen, and the header pins the
    // question below any earlier prose.
    private static func question(in lines: ArraySlice<String>) -> String? {
        var candidates: [String] = []
        var headerCandidates: [String] = []
        var paragraph: [String] = []
        var followsQuestionHeader = false
        var isSkippingMetadataBlock = false

        func closeParagraph() {
            if let candidate = compact(paragraph) {
                candidates.append(candidate)
                if followsQuestionHeader {
                    headerCandidates.append(candidate)
                }
            }
            paragraph = []
            followsQuestionHeader = false
        }

        for line in lines {
            let value = line.trimmingCharacters(in: .whitespaces)
            let lowercased = value.lowercased()
            if value.isEmpty {
                closeParagraph()
                isSkippingMetadataBlock = false
                continue
            }
            if lowercased.hasPrefix("reason:") ||
                lowercased == "bash command" {
                closeParagraph()
                isSkippingMetadataBlock = true
                continue
            }
            if lowercased.hasPrefix("question ") {
                followsQuestionHeader = true
                continue
            }
            guard !isSkippingMetadataBlock,
                  !isHorizontalRule(value),
                  !value.hasPrefix("$"),
                  !value.hasPrefix("›"),
                  !value.hasPrefix("❯"),
                  !isQuestionTabStrip(value) else {
                continue
            }
            paragraph.append(value)
        }
        closeParagraph()

        if let question = headerCandidates.last {
            return question
        }
        return candidates.last
    }

    // Claude's question forms draw navigation chrome above the question: one
    // "☐"/"☑" tab per question plus a "✔ Submit" tab, wrapped in "←"/"→" scroll
    // arrows when the strip is wider than the pane.
    private static func isQuestionTabStrip(_ value: String) -> Bool {
        let stripped = value.drop { $0 == "←" || $0 == " " }
        return ["☐", "☑", "✔"].contains { stripped.hasPrefix($0) }
    }

    private static func isNavigationHint(_ line: String) -> Bool {
        let value = line.lowercased()
        guard value.contains("to navigate") else { return false }
        return value.contains("arrow") || value.contains("↑")
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            guard self[previous].isWhitespace else { break }
            end = previous
        }
        return String(self[..<end])
    }
}
