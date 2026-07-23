// Selects a short, display-safe excerpt from rendered agent terminal screens.
// This module owns the cache Shepherd shows in agent rows: the latest agent
// message the extractor believes is on screen. A working read may replace the
// cache from a single observation, so streaming prose appears while the agent
// is still writing it; a settled (done/idle) read must produce the same
// changed message twice in a row before it replaces the cache, so one
// mid-redraw capture cannot stick until the next status change. Blocked
// screens publish their exact prompt without touching the cache. A screen
// with no recognizable message keeps the cached message; while working with
// an empty cache, the agent's live activity line fills in.
//
// The cache is best-effort by design: it trusts that the newest non-tool
// prose block on a coherent screen is the agent's latest message. Scrolled
// history can therefore be cached briefly; the next read after the viewport
// returns to the tail corrects it.
//
// The extractor does not read Herdr, persist terminal content, log text, or
// truncate for a particular view width. Its caller supplies already-rendered
// plain text and projects the machine's display state into an in-memory
// cache; AgentExcerptUpdate describes the direct cache mutation for callers
// that do not also track loading.

import Foundation

/// One line selected from an agent's rendered terminal.
///
/// `kind` describes why the line is useful, not a role asserted by Herdr.
/// `confidence` reflects the extractor evidence. Shepherd displays only values
/// returned here; low-confidence guesses remain internal and are never emitted.
struct AgentExcerpt: Equatable {
    enum Kind: Equatable {
        /// A tool, subagent, or other operation visible while the agent works.
        /// Published only while no agent message has been cached yet.
        case activity
        /// A question or permission form that requires a person's action.
        case attention
        /// The agent message most recently seen on screen. While the agent
        /// works this may be text still being streamed.
        case response
    }

    enum Confidence: Equatable {
        /// Multiple signals agree, but the text still came from a terminal UI.
        case medium
        /// The text came from an exact, agent-specific blocker structure.
        case high
    }

    var text: String
    var kind: Kind
    var confidence: Confidence
    /// Pane revision associated with the accepted screen. Presentation does not
    /// show this value; callers can use it for freshness diagnostics.
    var screenRevision: UInt64
}

/// UI-facing load state for one supported agent's display-safe Excerpt.
///
/// `loading` lasts until a coherent screen produces the first observation.
/// `empty` means a coherent observation completed without a line Shepherd can
/// publish.
/// Unsupported agents do not receive this state; FleetStore represents them
/// with nil so their rows keep the ordinary two-line layout.
enum AgentExcerptState: Equatable {
    case loading
    case available(AgentExcerpt)
    case empty
}

/// A coherent terminal observation supplied by the Herdr read monitor.
///
/// The caller must read the same tracked terminal's status immediately before
/// and after `agent.read`; observations whose statuses differ are ignored.
/// `text` must be plain text with ANSI control sequences removed. `revision` is
/// the coherent pane-lifecycle marker chosen by the caller, not a semantic
/// message ID. AgentReadMonitor derives it from equal bracketing `agent.get`
/// revisions because protocol 17 does not relate `pane_read.revision` to that
/// value.
struct AgentExcerptInput: Equatable {
    var statusBeforeRead: AgentStatus
    var statusAfterRead: AgentStatus
    var revision: UInt64
    var text: String
}

/// Mutation the owner applies to its displayed excerpt cache.
///
/// An explicit update distinguishes an inconclusive frame (`keep`) from a
/// lifecycle boundary that invalidates the currently displayed value (`remove`).
enum AgentExcerptUpdate: Equatable {
    case keep
    case replace(AgentExcerpt)
    case remove
}

/// Stateful, value-semantic dispatcher for the agent grammars Shepherd supports.
///
/// Create one machine per agent session. Replacing the session, changing the
/// canonical agent, or removing the terminal must replace or discard the
/// machine; otherwise another conversation could inherit this cache. The
/// machine is synchronous and performs no I/O.
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
    /// Settled-screen replacement candidate. The same text must arrive in two
    /// consecutive settled reads before it becomes the accepted message; any
    /// other status observed in between cancels the candidate.
    private var pendingResponse: String?
    private var pendingResponseCount = 0
    /// The cached latest agent message. Working reads replace it directly so
    /// streaming text stays current; settled reads replace it only through the
    /// two-read verification.
    private var acceptedResponse: AgentExcerpt?
    private(set) var excerpt: AgentExcerpt?
    /// True after a settled read proposed a changed message. The caller should
    /// issue another read promptly instead of waiting for the next poll tick.
    private(set) var requiresVerificationRead = false

    /// Returns nil for an agent whose rendered screen grammar Shepherd does not
    /// support. Agent aliases are normalized here so callers do not branch.
    init?(agentID: String) {
        guard let grammar = Grammar(agentID: agentID) else { return nil }
        self.grammar = grammar
    }

    /// Whether Shepherd has a terminal grammar for this agent identifier.
    ///
    /// Read monitors use this before issuing an RPC, so an unsupported agent
    /// never contributes screen text to the Excerpt cache.
    static func supports(agentID: String) -> Bool {
        Grammar(agentID: agentID) != nil
    }

    /// Ingests one screen and returns the display-cache mutation it causes.
    ///
    /// Working replaces the cached message with the newest visible one, or
    /// publishes current activity while the cache is empty. Blocked publishes
    /// only an exact prompt and leaves the cache untouched. Done/idle requires
    /// two matching observations before a changed message replaces the cache.
    /// A revision regression clears the cache because it indicates a restarted
    /// terminal lifecycle. A suppressed CLI overlay contributes nothing and
    /// keeps the cache on display.
    mutating func ingest(_ input: AgentExcerptInput) -> AgentExcerptUpdate {
        guard input.statusBeforeRead == input.statusAfterRead else {
            cancelPendingVerification()
            return .keep
        }
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

    /// Requires two consecutive settled observations of the same changed text
    /// before it replaces the cache. The monitor observes
    /// requiresVerificationRead and schedules the second read without waiting
    /// for the next snapshot poll.
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
        // Keep the published value until publish(_:) computes the explicit
        // remove/replace mutation the caller must apply after the reset.
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

/// Normalized terminal rows shared by the agent-specific grammars.
///
/// Herdr can return non-breaking spaces and terminal-width padding. Replacing
/// only those representation details preserves indentation used to recognize
/// wrapped response lines and tool trees.
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

    /// Selects the question/title immediately preceding a numbered choice form.
    /// Agent-specific callers invoke this only while Herdr reports blocked, so
    /// identical words inside a completed response cannot become attention text.
    ///
    /// A form's question sits above its first choice, but the choice list can
    /// be split by horizontal rules: Claude renders the escape-hatch "Chat
    /// about this" row (sometimes numbered as a choice) below its own rule.
    /// The search therefore starts at the bottom choice and, when the region
    /// above it holds no question text, crosses one rule at a time to the
    /// choices above. A hint line ends the walk because it closes a previous,
    /// already-answered form.
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
            // A previous form's final hint bounds the region the same way a
            // rule does, for CLIs that render two forms without a rule
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

    /// Extracts the question from the lines between a form boundary and its
    /// first choice. Prefers the last paragraph ending in "?" (half- or
    /// full-width), then a paragraph introduced by a "Question N/M" header
    /// (the region can reach back to the top of the screen when the form has
    /// no leading rule, so the header pins the right paragraph), then the
    /// region's first paragraph as its title.
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
            // "☐"/"☑" lines are Claude's per-question tab titles, not the
            // question text itself.
            guard !isSkippingMetadataBlock,
                  !isHorizontalRule(value),
                  !value.hasPrefix("$"),
                  !value.hasPrefix("›"),
                  !value.hasPrefix("❯"),
                  !value.hasPrefix("☐"),
                  !value.hasPrefix("☑") else {
                continue
            }
            paragraph.append(value)
        }
        closeParagraph()

        if let question = candidates.last(where: {
            $0.hasSuffix("?") || $0.hasSuffix("？")
        }) {
            return question
        }
        if let question = headerCandidates.last {
            return question
        }
        return candidates.first
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
