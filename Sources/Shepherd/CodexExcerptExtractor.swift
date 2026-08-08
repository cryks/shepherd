// Codex mixes assistant prose, tool history, live activity, the composer, and
// status chrome into one transcript, all with the same bullet marker. Position
// is the only reliable signal: a message sits directly below the user prompt
// echo on turns without tool work, or below the separator Codex draws between
// a turn's tool work and the message streamed after it. A bulleted block with
// no such anchor above it is tool history or a system cell, however prose-like
// its title.

import Foundation

enum CodexExcerptExtractor {
    private struct Block {
        var title: String
        var lines: [String]
        var startIndex: Int
    }

    // An anchor whose next block is tool, system, or live-status output falls
    // back to the anchor above it, so a previous turn's message stays selected
    // while new work streams below it.
    static func latestResponse(in screen: ExcerptScreen) -> String? {
        let blocks = blocks(in: screen)
        for anchorIndex in anchorIndices(in: screen).reversed() {
            guard let block = firstBlock(
                after: anchorIndex,
                in: screen,
                blocks: blocks
            ),
                !isLiveStatusTitle(block.title),
                !isToolOrSystem(block) else {
                continue
            }
            if let text = ExcerptText.compact(block.lines) {
                return text
            }
        }
        return orphanHeadResponse(in: screen)
    }

    // The composer carries the same "› "/"» " prefix as a prompt echo. It is
    // accepted here anyway because only footer chrome follows it, so it yields
    // no block.
    private static func anchorIndices(in screen: ExcerptScreen) -> [Int] {
        screen.lines.indices.filter { index in
            let line = screen.lines[index]
            return isTurnSeparator(line) || isPromptEcho(line)
        }
    }

    private static func isPromptEcho(_ line: String) -> Bool {
        line.hasPrefix("› ") || line.hasPrefix("» ")
    }

    // Blank and two-space-indented lines are an echo's continuation lines or
    // footer chrome, so the walk passes over them to the first column-0 line.
    private static func firstBlock(
        after anchorIndex: Int,
        in screen: ExcerptScreen,
        blocks: [Block]
    ) -> Block? {
        for index in (anchorIndex + 1)..<screen.lines.endIndex {
            let line = screen.lines[index]
            if line.isEmpty || line.hasPrefix("  ") {
                continue
            }
            return blocks.first { $0.startIndex == index }
        }
        return nil
    }

    // Once a turn runs longer than a minute, Codex labels the separator
    // ("─ Worked for 20m 25s ────"), and the label breaks the plain rule test.
    private static func isTurnSeparator(_ line: String) -> Bool {
        ExcerptText.isHorizontalRule(line) ||
            (line.hasPrefix("─ ") && line.hasSuffix("─"))
    }

    // A message taller than the viewport pushes its `•` head above the top
    // edge, so no anchor can reach it. What is left at the top of the screen is
    // the tail of that message, and its last paragraph holds the conclusion.
    private static func orphanHeadResponse(in screen: ExcerptScreen) -> String? {
        var paragraphs: [[String]] = []
        var paragraph: [String] = []
        for line in screen.lines {
            if line.isEmpty {
                if !paragraph.isEmpty {
                    paragraphs.append(paragraph)
                    paragraph = []
                }
                continue
            }
            guard isOrphanProse(line) else { break }
            paragraph.append(line.trimmingCharacters(in: .whitespaces))
        }
        if !paragraph.isEmpty {
            paragraphs.append(paragraph)
        }
        guard let tail = paragraphs.last else { return nil }
        return ExcerptText.compact(tail)
    }

    // Prose continuation is indented exactly two spaces; tool detail lines are
    // deeper or start with a tree glyph, and chrome (composer, dividers, the
    // status bar's leading "─"/"»" forms) starts at column 0.
    private static func isOrphanProse(_ line: String) -> Bool {
        guard line.hasPrefix("  ") else { return false }
        let value = line.dropFirst(2)
        guard let first = value.first, first != " " else { return false }
        return !"⎿└├↳❯›»•◦".contains(first)
    }

    static func activity(in screen: ExcerptScreen) -> String? {
        guard let title = blocks(in: screen).last?.title,
              let summary = liveStatusSummary(title) else { return nil }
        return ExcerptText.compact([summary])
    }

    static func attention(in screen: ExcerptScreen) -> String? {
        if let prompt = ExcerptText.attentionPrompt(in: screen) {
            return prompt
        }

        let overlayLines = screen.lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(6)
        for line in overlayLines.reversed() {
            let value = line.trimmingCharacters(in: .whitespaces)
            let lowercased = value.lowercased()
            if let marker = value.range(
                of: "[y/n]",
                options: .caseInsensitive
            ) {
                return ExcerptText.compact([
                    String(value[..<marker.lowerBound])
                ])
            }
            if lowercased == "allow command?" {
                return ExcerptText.compact([value])
            }
        }
        return nil
    }

    // Codex's scroll mode covers the transcript with a pager whose footer is
    // matched here, so nothing on such a screen belongs to the conversation.
    static func isSuppressed(_ screen: ExcerptScreen) -> Bool {
        let text = screen.lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(8)
            .joined(separator: "\n")
            .lowercased()
        return text.contains("↑/↓ to scroll") &&
            text.contains("pgup/pgdn to") &&
            text.contains("home/end to jump") &&
            text.contains("q to quit") &&
            (text.contains("esc to edit prev") ||
                text.contains("esc/← to edit prev"))
    }

    private static func blocks(in screen: ExcerptScreen) -> [Block] {
        var result: [Block] = []
        var index = screen.lines.startIndex

        while index < screen.lines.endIndex {
            let line = screen.lines[index]
            guard let title = markerContent(line) else {
                index += 1
                continue
            }

            var blockLines = [title]
            var next = index + 1
            while next < screen.lines.endIndex {
                let candidate = screen.lines[next]
                if candidate.isEmpty ||
                    markerContent(candidate) != nil ||
                    ExcerptText.isHorizontalRule(candidate) {
                    break
                }
                let trimmed = candidate.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("›") || trimmed.hasPrefix("»") {
                    break
                }
                guard candidate.hasPrefix("  ") else { break }
                blockLines.append(trimmed)
                next += 1
            }

            result.append(Block(
                title: title,
                lines: blockLines,
                startIndex: index
            ))
            index = max(next, index + 1)
        }
        return result
    }

    private static func markerContent(_ line: String) -> String? {
        for marker in ["• ", "◦ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func isToolOrSystem(_ block: Block) -> Bool {
        isSystemCellTitle(block.title) ||
            block.lines.dropFirst().contains { line in
                line.hasPrefix("└") ||
                    line.hasPrefix("├") ||
                    line.hasPrefix("↳")
            }
    }

    // System cells use the same marker as prose and often have no detail
    // lines, so their titles are the only thing left to recognize them by.
    private static func isSystemCellTitle(_ title: String) -> Bool {
        if [
            "Called",
            "Context compacted",
            "Explored",
            "Exploring",
            "Finished waiting",
            "Messages to be submitted at end of turn",
            "Queued follow-up messages",
            "Updated Plan",
            "Viewed Image",
        ].contains(title) {
            return true
        }
        if [
            "Generated Image:",
            "Loading MCP inventory",
            "Model interrupted to ",
            "Permissions updated to ",
            "Running PostToolUse hook:",
            "Running PreToolUse hook:",
            "Running SessionStart hook:",
            "Running UserPromptSubmit hook:",
            "Started `",
            "Thread forked from ",
            "Waited for background terminal",
            "Waiting for background terminal",
        ].contains(where: title.hasPrefix) {
            return true
        }
        if title.hasPrefix("Calling ") && title.contains("(") {
            return true
        }
        if title == "Searching the web" {
            return true
        }
        if ["Closed ", "Resumed ", "Sent input to "]
            .contains(where: title.hasPrefix) &&
            title.contains("[") {
            return true
        }
        if title.hasPrefix("Spawned ") &&
            (title.contains("[") || title.contains(" (gpt-")) {
            return true
        }
        if title.hasPrefix("Waiting for ") &&
            (title == "Waiting for agents" ||
                title.hasSuffix(" agents") ||
                title.contains("[")) {
            return true
        }
        if title.hasPrefix("Searched ") {
            return true
        }
        return ["Added ", "Deleted ", "Edited "]
            .contains(where: title.hasPrefix) &&
            title.contains(" (+") &&
            title.hasSuffix(")")
    }

    private static func isLiveStatusTitle(_ title: String) -> Bool {
        liveStatusSummary(title) != nil
    }

    private static func liveStatusSummary(_ title: String) -> String? {
        guard let metadataStart = title.range(
            of: " (",
            options: .backwards
        ),
              title.hasSuffix(")") else {
            return nil
        }
        let metadataEnd = title.index(before: title.endIndex)
        let metadata = title[metadataStart.upperBound..<metadataEnd]
        guard let separator = metadata.range(of: " • "),
              isElapsedDuration(metadata[..<separator.lowerBound]) else {
            return nil
        }
        // A narrow pane truncates the hint to an ellipsis, so a prefix counts.
        let interruptHint = metadata[separator.upperBound...].lowercased()
        guard interruptHint == "esc to interrupt" ||
                (interruptHint.hasPrefix("esc to interr") &&
                    interruptHint.hasSuffix("…")) else {
            return nil
        }
        return String(title[..<metadataStart.lowerBound])
    }

    // Codex writes elapsed time as "<1s" below a second and as "1.5s" with a
    // fraction, which is why the leading "<" and one decimal point are allowed.
    private static func isElapsedDuration(_ value: Substring) -> Bool {
        let components = value.split(separator: " ")
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            guard let unit = component.last,
                  "hms".contains(unit) else {
                return false
            }
            var amount = component.dropLast()
            if amount.first == "<" {
                amount = amount.dropFirst()
            }
            guard !amount.isEmpty else { return false }
            var decimalPoints = 0
            var hasDigit = false
            for character in amount {
                if character == "." {
                    decimalPoints += 1
                } else if character.isNumber {
                    hasDigit = true
                } else {
                    return false
                }
            }
            return hasDigit && decimalPoints <= 1
        }
    }
}
