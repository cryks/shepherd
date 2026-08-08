// Claude marks prose and tool output with the same leading glyph, so blocks
// can only be told apart by their shape: this parser rejects the tool-shaped
// ones and takes the newest block that survives.

import Foundation

enum ClaudeExcerptExtractor {
    private struct Block {
        var title: String
        var lines: [String]
    }

    private static let toolNames = [
        "Bash",
        "Read",
        "Edit",
        "Write",
        "Glob",
        "Grep",
        "WebFetch",
        "WebSearch",
        "Task",
        "TaskOutput",
        "KillShell",
        "NotebookEdit",
        "AskUserQuestion",
        "Skill",
        "EnterPlanMode",
        "ExitPlanMode",
        "TodoWrite",
        "LSP",
    ]

    // A tool batch whose `⎿` detail lines scrolled out of view looks like
    // prose here. The machine's cache self-corrects on a later read.
    static func latestResponse(in screen: ExcerptScreen) -> String? {
        for block in blocks(in: screen).reversed() where !isTool(block) {
            if let text = ExcerptText.compact(block.lines) {
                return text
            }
        }
        return orphanHeadResponse(in: screen)
    }

    // A message taller than the viewport pushes its `⏺` head above the top
    // edge, so blocks(in:) finds nothing. What is left at the top of the screen
    // is the tail of that message, and its last paragraph holds the conclusion.
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
    // deeper or start with a tree glyph, and chrome starts at column 0.
    private static func isOrphanProse(_ line: String) -> Bool {
        guard line.hasPrefix("  ") else { return false }
        let value = line.dropFirst(2)
        guard let first = value.first, first != " " else { return false }
        return !"⎿└├↳❯›»◯⏺●".contains(first)
    }

    // Frames of the working footer's animated leading glyph. A read can catch
    // any frame, so every frame must be accepted as the line's first character.
    private static let spinnerFrames = ["·", "✢", "✳", "✶", "✻", "✽"]

    static func activity(in screen: ExcerptScreen) -> String? {
        let footerLines = screen.lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(12)
        for line in footerLines.reversed() {
            // Current builds draw the spinner footer; the "  ◯ " form below is
            // for older builds still in use.
            if let summary = currentFooterActivity(line) {
                return summary
            }
            guard line.hasPrefix("  ◯ ") else { continue }

            let value = String(line.dropFirst(2))
            var summary = String(value.dropFirst(2))
            guard let separator = summary.range(of: "  "),
                  let metadata = summary.range(of: " · "),
                  separator.upperBound < metadata.lowerBound else { continue }
            summary = String(
                summary[separator.upperBound..<metadata.lowerBound]
            )
            if let compact = ExcerptText.compact([summary]) {
                return compact
            }
        }

        return nil
    }

    // The `<elapsed> · ↓ <n> tokens` pair is the fingerprint: prose that starts
    // with a spinner glyph and ends in parentheses cannot reproduce it. While
    // the model thinks, the footer appends further segments (for example
    // `· thought for 104s`), so only the first two are checked.
    private static func currentFooterActivity(_ line: String) -> String? {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard spinnerFrames.contains(where: { value.hasPrefix($0 + " ") }),
              let metadataStart = value.range(
                  of: " (",
                  options: .backwards
              ),
              value.hasSuffix(")") else {
            return nil
        }
        let metadataEnd = value.index(before: value.endIndex)
        let metadata = value[metadataStart.upperBound..<metadataEnd]
        let segments = metadata.components(separatedBy: " · ")
        guard segments.count >= 2,
              isElapsedDuration(Substring(segments[0])),
              isTokenCount(Substring(segments[1])) else {
            return nil
        }
        let summaryStart = value.index(value.startIndex, offsetBy: 2)
        return ExcerptText.compact([
            String(value[summaryStart..<metadataStart.lowerBound])
        ])
    }

    private static func isElapsedDuration(_ value: Substring) -> Bool {
        let components = value.split(separator: " ")
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            guard let unit = component.last,
                  "hms".contains(unit) else {
                return false
            }
            let amount = component.dropLast()
            return !amount.isEmpty && amount.allSatisfy(\.isNumber)
        }
    }

    private static func isTokenCount(_ value: Substring) -> Bool {
        guard value.hasPrefix("↓ ") else { return false }
        let countAndUnit = value.dropFirst(2)
        let suffix: Substring
        if countAndUnit.hasSuffix(" tokens") {
            suffix = " tokens"
        } else if countAndUnit.hasSuffix(" token") {
            suffix = " token"
        } else {
            return false
        }
        let count = countAndUnit.dropLast(suffix.count)
        guard !count.isEmpty else { return false }
        return count.allSatisfy {
            $0.isNumber || $0 == "." || $0 == "," ||
                $0 == "k" || $0 == "K" || $0 == "m" || $0 == "M"
        }
    }

    static func attention(in screen: ExcerptScreen) -> String? {
        let overlayLines = screen.lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(8)
        let text = overlayLines.joined(separator: "\n").lowercased()
        if text.contains("run a dynamic workflow?") &&
            text.contains("esc to cancel") {
            return overlayLines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { $0.lowercased().contains("run a dynamic workflow?") }
                .flatMap { ExcerptText.compact([$0]) }
        }
        return ExcerptText.attentionPrompt(in: screen)
    }

    // The transcript viewer and the model picker cover the transcript, so
    // nothing on such a screen belongs to the conversation.
    static func isSuppressed(_ screen: ExcerptScreen) -> Bool {
        if isScrolledBack(screen) { return true }
        let nonEmptyLines = screen.lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let transcriptText = nonEmptyLines
            .suffix(3)
            .joined(separator: "\n")
            .lowercased()
        let isTranscriptViewer =
            transcriptText.contains("showing detailed transcript") &&
            (transcriptText.contains("↑↓ scroll") ||
                transcriptText.contains("? for shortcuts") ||
                (transcriptText.contains("ctrl+o") &&
                    transcriptText.contains("to toggle")) ||
                (transcriptText.contains("ctrl+e") &&
                    (transcriptText.contains("show all") ||
                        transcriptText.contains("collapse"))))
        let menuText = screen.lines.joined(separator: "\n").lowercased()
        let isModelPicker =
            menuText.contains("select model") &&
            menuText.contains("enter to set as default") &&
            menuText.contains("esc to cancel") &&
            !menuText.contains("do you want to proceed?") &&
            !menuText.contains("enter to select")
        return isTranscriptViewer || isModelPicker
    }

    // Above the transcript tail, Claude centers "Jump to bottom (click) ↓" (or
    // "<n> new messages (click) ↓") over the bottom transcript row. The screen
    // shows history, and the indicator overwrites the characters under it, so
    // extraction would revive an old message with the indicator spliced in.
    //
    // Matching only that one row keeps the same words, quoted inside a message,
    // from counting. The composer is found by the rule directly above it:
    // history prompt echoes also start with "❯" but have no such rule.
    private static func isScrolledBack(_ screen: ExcerptScreen) -> Bool {
        let lines = screen.lines
        guard let composer = lines.lastIndex(where: { $0.hasPrefix("❯") }),
              composer > lines.startIndex,
              ExcerptText.isHorizontalRule(lines[composer - 1]) else {
            return false
        }
        guard let bottomRow = lines[..<(composer - 1)].lastIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else {
            return false
        }
        return containsScrollbackIndicator(lines[bottomRow])
    }

    // The indicator lands mid-row with the covered text resuming after it, so
    // it is matched anywhere in the row rather than as a prefix.
    private static func containsScrollbackIndicator(_ line: String) -> Bool {
        if line.contains("Jump to bottom (click) ↓") { return true }
        guard let range = line.range(of: " new message") else { return false }
        var rest = line[range.upperBound...]
        if rest.hasPrefix("s") { rest = rest.dropFirst() }
        guard rest.hasPrefix(" (click) ↓") else { return false }
        return line[..<range.lowerBound].last?.isNumber == true
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
                guard candidate.hasPrefix("  ") else { break }
                blockLines.append(candidate.trimmingCharacters(in: .whitespaces))
                next += 1
            }

            result.append(Block(title: title, lines: blockLines))
            index = max(next, index + 1)
        }
        return result
    }

    private static func markerContent(_ line: String) -> String? {
        for marker in ["⏺ ", "● "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func isTool(_ block: Block) -> Bool {
        if toolNames.contains(where: { block.title.hasPrefix($0 + "(") }) {
            return true
        }
        if block.title.hasPrefix("User answered") &&
            block.title.contains(":") {
            return true
        }
        if block.title.first?.isNumber == true &&
            block.title.contains(" agents finished") {
            return true
        }
        return block.lines.dropFirst().contains { $0.hasPrefix("⎿") }
    }
}
