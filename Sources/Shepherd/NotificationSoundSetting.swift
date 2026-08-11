import Foundation
import Observation
import UserNotifications

enum NotificationSoundChoice: Hashable {
    case none
    case systemDefault
    case named(String)
}

// The "named:" prefix keeps a sound file that happens to be called "default"
// from colliding with the systemDefault case.
extension NotificationSoundChoice: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "":
            self = .none
        case "default":
            self = .systemDefault
        default:
            guard rawValue.hasPrefix("named:") else { return nil }
            self = .named(String(rawValue.dropFirst("named:".count)))
        }
    }

    var rawValue: String {
        switch self {
        case .none: ""
        case .systemDefault: "default"
        case .named(let name): "named:" + name
        }
    }
}

extension NotificationSoundChoice {
    // UNNotificationSound resolves a bare file name against the app bundle and
    // the Library/Sounds folders, which on macOS includes /System/Library/Sounds.
    var notificationSound: UNNotificationSound? {
        switch self {
        case .none:
            nil
        case .systemDefault:
            .default
        case .named(let name):
            UNNotificationSound(named: UNNotificationSoundName(name + ".aiff"))
        }
    }
}

// Sole writer of the per-kind notification sound preference. Delivery reads it
// through AgentNotificationCenter's sound closure on each deliver.
@Observable @MainActor
final class NotificationSoundSetting {
    static let shared = NotificationSoundSetting()

    static let doneKey = "NotificationSoundDone"
    static let blockedKey = "NotificationSoundBlocked"

    // The same catalog System Settings offers as alert sounds; Shepherd ships
    // no sounds of its own.
    static let systemSoundNames: [String] = {
        let sounds = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: sounds,
            includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "aiff" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }()

    var doneSound: NotificationSoundChoice {
        didSet { defaults.set(doneSound.rawValue, forKey: Self.doneKey) }
    }

    var blockedSound: NotificationSoundChoice {
        didSet { defaults.set(blockedSound.rawValue, forKey: Self.blockedKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        doneSound = Self.storedChoice(defaults, key: Self.doneKey)
        blockedSound = Self.storedChoice(defaults, key: Self.blockedKey)
    }

    func choice(for kind: AttentionNoticeKind) -> NotificationSoundChoice {
        switch kind {
        case .done: doneSound
        case .blocked: blockedSound
        }
    }

    // A missing key reads as "", and both it and a hand-edited value land on
    // silence, the pre-feature behavior.
    private static func storedChoice(
        _ defaults: UserDefaults,
        key: String
    ) -> NotificationSoundChoice {
        NotificationSoundChoice(rawValue: defaults.string(forKey: key) ?? "") ?? .none
    }
}
