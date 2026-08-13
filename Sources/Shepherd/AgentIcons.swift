// Assets are Resources/AgentMarks/<agent>-<style>.pdf, where <agent> matches
// herdr's detection label (claude, codex, ...). The mono fill is plain black
// because AgentRow draws it as a template and repaints it with the foreground
// color, so that fill never reaches the screen.

import AppKit

// The rawValue is the asset filename suffix.
enum AgentIconStyle: String {
    case mono
    case color

    func usesTemplate(agent: String, appearanceIsDark: Bool) -> Bool {
        switch self {
        case .mono:
            return true
        case .color:
            // Grok's color mark is black ink. Original drawing vanishes on a
            // dark panel, so follow the (light) text color there.
            return appearanceIsDark && agent == "grok"
        }
    }
}

@MainActor
enum AgentIcons {
    // Misses are cached as nil as well, to keep a Bundle lookup out of every
    // row redraw.
    private static var cache: [String: NSImage?] = [:]

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
