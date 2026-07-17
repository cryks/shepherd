// Resolves an agent kind (Pane.agent) to a brand mark image.
// Assets are vectors at Resources/AgentMarks/<agent>-<style>.pdf, where the
// <agent> in the filename matches herdr's detection label (claude, codex, ...).
// mono is a solid black fill. The display side (AgentRow) renders it as a
// template and repaints it with the foreground color, so this fill color itself
// never appears on screen.
// color is filled with the brand colors as-is and is meant to be rendered original.
// Which one is used is chosen by AgentRow according to the setting (colorAgentIconsKey).
// Agent names without an asset return nil, and the caller falls back to the
// conventional text display.

import AppKit

/// Mark fill variants. The rawValue is the asset filename suffix.
enum AgentIconStyle: String {
    case mono
    case color
}

@MainActor
enum AgentIcons {
    /// Cache of resolution results. Agents without an asset are remembered as
    /// nil too, so a Bundle lookup doesn't run on every row redraw.
    private static var cache: [String: NSImage?] = [:]

    /// Returns the mark for an agent name; nil when no matching asset exists.
    static func icon(for agent: String, style: AgentIconStyle = .mono) -> NSImage? {
        let key = "\(agent)-\(style.rawValue)"
        if let cached = cache[key] { return cached }
        let image = Bundle.module
            .url(forResource: key, withExtension: "pdf", subdirectory: "AgentMarks")
            .flatMap { NSImage(contentsOf: $0) }
        cache[key] = image
        return image
    }
}
