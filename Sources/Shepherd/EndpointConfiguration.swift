import Foundation

struct HerdrSourceID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    static let local = HerdrSourceID(rawValue: "local")

    // The argument exists for tests and migrations that must reproduce a known
    // UUID; adding a remote from the UI always mints a fresh one.
    static func remote(uuid: UUID = UUID()) -> HerdrSourceID {
        HerdrSourceID(rawValue: "remote:\(uuid.uuidString.lowercased())")
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    // Encoded as a bare string so the persisted configuration JSON does not
    // change shape if this type gains stored properties.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    fileprivate var isRemote: Bool {
        let prefix = "remote:"
        guard rawValue.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(rawValue.dropFirst(prefix.count))) != nil
    }
}

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

// A fixed set rather than a free number: the poll drives SSH traffic, and typed
// input could ask for a rate close to a busy loop.
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

struct RemoteSourceConfiguration: Identifiable, Codable, Equatable, Sendable {
    let id: HerdrSourceID
    var label: String
    var sshAlias: String
    var sessionName: String?
    var pollInterval: RemotePollingInterval
    // isVisible outranks isEnabled: false hides the endpoint entirely, while
    // isEnabled keeps its stored value so restoring visibility also restores
    // whatever monitoring state the user last chose. Either being false stops
    // FleetStore from building the Store and the SSH tunnel.
    var isVisible: Bool
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

    // Stored JSON may be hand-edited or written without the optional keys, so
    // those fall back to the product defaults instead of failing the decode.
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

    // The fallback lets the label stay empty, so adding a remote needs nothing
    // beyond its SSH destination.
    var displayName: String {
        let normalizedLabel = Self.trim(label)
        return normalizedLabel.isEmpty ? Self.trim(sshAlias) : normalizedLabel
    }

    var normalizedSessionName: String? {
        Self.normalizeSessionName(sessionName)
    }

    var validationError: RemoteSourceValidationError? {
        Self.validationError(for: normalized())
    }

    // Applied on load as well as on save: UserDefaults is user-writable, and
    // these values reach an ssh argv.
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

    // The destination is one argv entry, never a shell word, so punctuation needs
    // no grammar. Only a leading `-`, which ssh would read as an option, and
    // whitespace or control characters are unsafe.
    private static func isSafeSSHAlias(_ value: String) -> Bool {
        guard !value.hasPrefix("-") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    // Herdr's session grammar is [A-Za-z0-9._-]+, but it reserves "." and "..",
    // which that grammar would otherwise accept.
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

// Herdr pane and workspace IDs are unique only within one server, so the display
// layer keys on them together with the source.
struct SourcePaneID: Hashable, Sendable {
    let sourceID: HerdrSourceID
    let paneID: String
}

struct SourceWorkspaceID: Hashable, Sendable {
    let sourceID: HerdrSourceID
    let workspaceID: String
}

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

    static let live = userDefaults(.standard)

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
                    // One bad entry cannot be told apart from corrupt storage, and
                    // starting with no remotes beats refusing to start.
                    return []
                }
            },
            save: { configurations in
                // Validate the whole array first: a partial write would leave the
                // stored list disagreeing with what the user sees.
                let validated = try configurations.map { try $0.validated() }
                let data = try JSONEncoder().encode(validated)
                defaults.set(data, forKey: userDefaultsKey)
            }
        )
    }

    // Not private: tests write corrupt JSON to this exact key.
    static let userDefaultsKey = "RemoteHerdrSources"
}
