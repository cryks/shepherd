// Claude Code terminal grammar for AgentExcerptMachine. Claude renders prose
// and tools with the same leading message glyph, while its alternate-screen
// prompt and selection forms remain at the bottom. This parser rejects known
// tool-shaped blocks; the newest surviving prose block is the agent's latest
// visible message, which the shared state machine caches best-effort.

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

    /// The newest visible prose block, skipping tool blocks that follow it.
    /// A tool batch whose `⎿` detail lines scrolled out of view can be
    /// misclassified as prose; the cache self-corrects on a later read.
    static func latestResponse(in screen: ExcerptScreen) -> String? {
        for block in blocks(in: screen).reversed() where !isTool(block) {
            if let text = ExcerptText.compact(block.lines) {
                return text
            }
        }
        return orphanHeadResponse(in: screen)
    }

    /// A message longer than the viewport leaves only its continuation lines
    /// on screen: the `⏺` head is above the top edge, so no block is parsed.
    /// Those leading two-space-indented lines are the tail of the newest
    /// message; the last paragraph before the first marker, rule, or composer
    /// line carries its conclusion. Consulted only when no complete prose
    /// block is visible, so a complete newer block always wins.
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

    /// Prose continuation is indented exactly two spaces; tool detail lines
    /// are deeper or start with a tree glyph, and chrome starts at column 0.
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
            // Current Claude builds use a spinner footer with parenthesized
            // duration/token metadata; older builds use the circle form below.
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

    // The line's fingerprint is the metadata pair `<elapsed> · ↓ <n> tokens`,
    // which prose containing a spinner glyph and parentheses cannot reproduce.
    // While the model is thinking, the footer appends transient segments after
    // the token count (for example `· thought for 104s`); those carry no stable
    // information and are not validated.
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

    static func isSuppressed(_ screen: ExcerptScreen) -> Bool {
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
