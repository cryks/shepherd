// Owns the persistent configuration for the Herdr endpoints Shepherd monitors,
// plus the UI identities that stay collision-free across endpoints. This file
// persists SSH destinations, display settings, and the remote poll interval to
// UserDefaults; the socket path cache owned by RemoteTunnel, connection state,
// retry counts, errors, and fetched panes are not stored here.
// The local connection is represented by a fixed ID; remote connections keep
// the UUID minted at creation across subsequent restarts. Pane/workspace IDs
// returned by Herdr are unique only within a server, so the display layer must
// always combine them with the source ID.

import Foundation

/// Stable ID that identifies a Herdr endpoint within Shepherd.
/// `local` is used only by this Mac's default connection; remote configurations
/// are created with `remote(uuid:)`. Codable stores it as a single string so
/// the configuration JSON's structure does not depend on the ID's implementation details.
struct HerdrSourceID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    static let local = HerdrSourceID(rawValue: "local")

    /// Creates an ID for a remote connection. Pass the argument only when tests
    /// or configuration migrations need to reproduce the same UUID; a normal add
    /// operation uses the default to mint a fresh ID.
    static func remote(uuid: UUID = UUID()) -> HerdrSourceID {
        HerdrSourceID(rawValue: "remote:\(uuid.uuidString.lowercased())")
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Check used by RemoteSourceConfiguration to reject the reserved local ID and arbitrary strings.
    fileprivate var isRemote: Bool {
        let prefix = "remote:"
        guard rawValue.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(rawValue.dropFirst(prefix.count))) != nil
    }
}

/// Represents input that cannot be saved as a remote monitoring target.
/// Settings can map `validationError` directly to the error display on the input field.
enum RemoteSourceValidationError: Error, Equatable, LocalizedError {
    case invalidSourceID
    case emptySSHAlias
    case unsafeSSHAlias(String)
    case invalidSessionName(String)

    var errorDescription: String? {
        switch self {
        case .invalidSourceID:
            trStored(
                "The remote connection ID is invalid",
                ja: "リモート接続の ID が不正です"
            )
        case .emptySSHAlias:
            trStored(
                "Enter an SSH destination",
                ja: "SSH 接続先を入力してください"
            )
        case .unsafeSSHAlias:
            trStored(
                "The SSH destination cannot start with a hyphen or contain whitespace or control characters",
                ja: "SSH 接続先には先頭のハイフン、空白、制御文字を使えません"
            )
        case .invalidSessionName:
            trStored(
                "Herdr session names can use only letters, digits, and . _ -",
                ja: "Herdr session 名には英数字と . _ - だけを使えます"
            )
        }
    }
}

/// session.snapshot polling interval for a remote endpoint. The settings UI
/// presents only this enumeration, so arbitrary decimal input cannot create a
/// busy loop or unintentionally high-frequency SSH traffic.
enum RemotePollingInterval: Int, CaseIterable, Codable, Identifiable, Sendable {
    case halfSecond = 500
    case oneSecond = 1_000
    case twoSeconds = 2_000
    case fiveSeconds = 5_000
    case tenSeconds = 10_000

    var id: Int { rawValue }

    var duration: Duration {
        .milliseconds(rawValue)
    }

    @MainActor var displayName: String {
        switch self {
        case .halfSecond:
            tr("0.5s", ja: "0.5秒")
        case .oneSecond:
            tr("1s", ja: "1秒")
        case .twoSeconds:
            tr("2s", ja: "2秒")
        case .fiveSeconds:
            tr("5s", ja: "5秒")
        case .tenSeconds:
            tr("10s", ja: "10秒")
        }
    }
}

/// Persistent configuration for a remote Herdr whose SSH tunnel Shepherd manages.
/// `sshAlias` is the destination passed to `/usr/bin/ssh` as a single argument;
/// it accepts a Host name from `~/.ssh/config` or `user@host`. When sessionName
/// is nil, the Herdr default session is monitored.
/// pollInterval is the per-endpoint session.snapshot interval; 2 seconds is used
/// when the stored value lacks it. On initialization and in the value returned
/// by `validated()`, surrounding whitespace is stripped and an empty session is
/// normalized to nil.
struct RemoteSourceConfiguration: Identifiable, Codable, Equatable, Sendable {
    let id: HerdrSourceID
    var label: String
    var sshAlias: String
    var sessionName: String?
    var pollInterval: RemotePollingInterval
    /// Per-host toggle in the settings Remotes list. It sits above isEnabled:
    /// while false, the section itself is absent from the menu panel and the
    /// monitor window, and FleetStore creates neither the Store nor the SSH
    /// tunnel regardless of isEnabled's value. isEnabled is persisted without
    /// being rewritten, so flipping back to true resumes monitoring for a
    /// remote that had monitoring ON.
    var isVisible: Bool
    /// Section checkbox in the menu panel. Even when false, the configuration
    /// and section header remain, and FleetStore creates neither the
    /// corresponding Store nor the SSH tunnel. The value survives a round trip
    /// through UserDefaults.
    var isEnabled: Bool

    init(
        id: HerdrSourceID = .remote(),
        label: String,
        sshAlias: String,
        sessionName: String? = nil,
        pollInterval: RemotePollingInterval = .twoSeconds,
        isVisible: Bool = true,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.label = Self.trim(label)
        self.sshAlias = Self.trim(sshAlias)
        self.sessionName = Self.normalizeSessionName(sessionName)
        self.pollInterval = pollInterval
        self.isVisible = isVisible
        self.isEnabled = isEnabled
    }

    /// pollInterval and isVisible have defaults and may be omitted from the JSON.
    /// Even for hand-edited UserDefaults or a minimal configuration representation,
    /// missing values are restored as the product defaults (pollInterval 2 seconds,
    /// isVisible true).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(HerdrSourceID.self, forKey: .id),
            label: try container.decode(String.self, forKey: .label),
            sshAlias: try container.decode(String.self, forKey: .sshAlias),
            sessionName: try container.decodeIfPresent(String.self, forKey: .sessionName),
            pollInterval: try container.decodeIfPresent(
                RemotePollingInterval.self,
                forKey: .pollInterval
            ) ?? .twoSeconds,
            isVisible: try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true,
            isEnabled: try container.decode(Bool.self, forKey: .isEnabled)
        )
    }

    /// Name used for list headers. Allowing an empty label and falling back to
    /// the SSH alias means adding a configuration does not require entering a
    /// display name.
    var displayName: String {
        let normalizedLabel = Self.trim(label)
        return normalizedLabel.isEmpty ? Self.trim(sshAlias) : normalizedLabel
    }

    /// Session passed to the Herdr CLI. Whitespace-only input becomes nil, the same as "default session".
    var normalizedSessionName: String? {
        Self.normalizeSessionName(sessionName)
    }

    /// First error for the current input. When nil, `validated()` succeeds.
    var validationError: RemoteSourceValidationError? {
        Self.validationError(for: normalized())
    }

    /// Returns the configuration with surrounding whitespace and empty sessions normalized.
    /// Called both when saving from Settings and when reading the persisted JSON
    /// back, so hand-edited UserDefaults cannot pass dangerous SSH arguments into
    /// the execution path.
    func validated() throws -> RemoteSourceConfiguration {
        let value = normalized()
        if let error = Self.validationError(for: value) {
            throw error
        }
        return value
    }

    private func normalized() -> RemoteSourceConfiguration {
        RemoteSourceConfiguration(
            id: id,
            label: label,
            sshAlias: sshAlias,
            sessionName: sessionName,
            pollInterval: pollInterval,
            isVisible: isVisible,
            isEnabled: isEnabled
        )
    }

    private static func validationError(
        for value: RemoteSourceConfiguration
    ) -> RemoteSourceValidationError? {
        guard value.id.isRemote else { return .invalidSourceID }
        guard !value.sshAlias.isEmpty else { return .emptySSHAlias }
        guard isSafeSSHAlias(value.sshAlias) else { return .unsafeSSHAlias(value.sshAlias) }

        if let sessionName = value.sessionName,
           !isValidSessionName(sessionName) {
            return .invalidSessionName(sessionName)
        }
        return nil
    }

    /// The SSH destination is passed as a single Process argv entry, so there is
    /// no need to narrow punctuation with a custom grammar. Only a leading `-`
    /// (interpreted as an option) and whitespace or control characters (which
    /// could look like multiple arguments or terminal control) are rejected.
    private static func isSafeSSHAlias(_ value: String) -> Bool {
        guard !value.hasPrefix("-") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    /// Checks Herdr's session grammar `[A-Za-z0-9._-]+` per ASCII scalar.
    /// `.` and `..` consist solely of grammar characters but are excluded because Herdr reserves them.
    private static func isValidSessionName(_ value: String) -> Bool {
        guard value != ".", value != "..", !value.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func normalizeSessionName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = trim(value)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case sshAlias
        case sessionName
        case pollInterval
        case isVisible
        case isEnabled
    }
}

/// Display identity that does not collide even when multiple Herdr servers have the same pane ID.
struct SourcePaneID: Hashable, Sendable {
    let sourceID: HerdrSourceID
    let paneID: String
}

/// Display identity that does not collide even when multiple Herdr servers have the same workspace ID.
struct SourceWorkspaceID: Hashable, Sendable {
    let sourceID: HerdrSourceID
    let workspaceID: String
}

/// Dependency boundary that separates reading and writing remote connection
/// configurations from the Store. `load` falls back to an empty array when
/// there is no stored value, the JSON is corrupt, or even one entry fails
/// validation. `save` validates every entry before writing them as a single
/// JSON array, so a partially updated configuration is never left behind.
struct RemoteSourceRepository {
    var load: () -> [RemoteSourceConfiguration]
    var save: ([RemoteSourceConfiguration]) throws -> Void

    init(
        load: @escaping () -> [RemoteSourceConfiguration],
        save: @escaping ([RemoteSourceConfiguration]) throws -> Void
    ) {
        self.load = load
        self.save = save
    }

    /// UserDefaults implementation used by the app itself. Persistence is
    /// limited to the JSON for `[RemoteSourceConfiguration]`.
    static let live = userDefaults(.standard)

    /// UserDefaults implementation that lets a test suite use the same JSON contract as production.
    static func userDefaults(_ defaults: UserDefaults) -> RemoteSourceRepository {
        RemoteSourceRepository(
            load: {
                guard let data = defaults.data(forKey: userDefaultsKey) else { return [] }
                do {
                    let decoded = try JSONDecoder().decode(
                        [RemoteSourceConfiguration].self,
                        from: data
                    )
                    return try decoded.map { try $0.validated() }
                } catch {
                    return []
                }
            },
            save: { configurations in
                let validated = try configurations.map { try $0.validated() }
                let data = try JSONEncoder().encode(validated)
                defaults.set(data, forKey: userDefaultsKey)
            }
        )
    }

    /// Kept internal so @testable tests can inject corrupt JSON into the same storage location.
    static let userDefaultsKey = "RemoteHerdrSources"
}
