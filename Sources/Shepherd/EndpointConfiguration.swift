// Shepherd が監視する Herdr 接続先の永続設定と、接続先をまたいで衝突しない
// UI 用 identity を所有する。このファイルが UserDefaults へ保存するのは SSH 接続先、
// 表示設定、リモートのpoll周期で、RemoteTunnelが所有するsocket path cache、接続状態、再試行回数、
// エラー、取得済み pane はここへ含めない。
// ローカル接続は固定 ID で表し、リモート接続は生成時の UUID を以後の再起動でも
// 使い続ける。Herdr が返す pane/workspace ID はサーバ内でのみ一意なので、表示層では
// 必ず source ID と組み合わせる。

import Foundation

/// Shepherd 内で Herdr 接続先を識別する安定 ID。
/// `local` はこの Mac の既定接続だけが使い、リモート設定は `remote(uuid:)` で作る。
/// Codable は文字列 1 個として保存し、設定 JSON の構造を ID の実装詳細へ依存させない。
struct HerdrSourceID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    static let local = HerdrSourceID(rawValue: "local")

    /// リモート接続用 ID を作る。引数はテストや設定移行で同じ UUID を再現するときだけ
    /// 指定し、通常の追加操作では既定値で新しい ID を発行する。
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

    /// RemoteSourceConfiguration が local の予約 ID や任意文字列を受け入れないための判定。
    fileprivate var isRemote: Bool {
        let prefix = "remote:"
        guard rawValue.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(rawValue.dropFirst(prefix.count))) != nil
    }
}

/// リモート監視先として保存できない入力を表す。
/// Settings は `validationError` をそのまま入力欄のエラー表示へ対応付けられる。
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

/// リモートendpointのsession.snapshot取得周期。設定UIはこの列挙だけを表示し、
/// 任意の小数入力からbusy loopや意図しない高頻度SSH通信を作らない。
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

/// Shepherd が SSH tunnel を管理するリモート Herdr の永続設定。
/// `sshAlias` は `/usr/bin/ssh` へ 1 引数で渡す接続先で、`~/.ssh/config` の Host 名や
/// `user@host` を受け入れる。sessionName が nil なら Herdr の既定 session を監視する。
/// pollInterval は接続先ごとのsession.snapshot周期で、保存値に無い場合は2秒を使う。
/// 初期化時と `validated()` の返値では前後の空白を除き、空の session は nil に揃える。
struct RemoteSourceConfiguration: Identifiable, Codable, Equatable, Sendable {
    let id: HerdrSourceID
    var label: String
    var sshAlias: String
    var sessionName: String?
    var pollInterval: RemotePollingInterval
    /// 設定 Remotes 一覧のホスト単位トグル。isEnabled の上位フラグで、false の間は
    /// メニューパネルと監視ウィンドウのセクション自体が出ず、FleetStore は isEnabled の
    /// 値にかかわらず Store・SSH tunnel を作らない。isEnabled は書き換えずに保存する
    /// ため、true へ戻すと監視 ON だった remote はそのまま監視を再開する。
    var isVisible: Bool
    /// メニューパネルの section checkbox。false でも設定と見出しは残り、FleetStore は
    /// 対応する Store・SSH tunnel を作らない。UserDefaults 往復後も値を維持する。
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

    /// 既定値を持つpollIntervalとisVisibleはJSONから省略できる。UserDefaultsの手編集や
    /// 設定の最小表現でも、未指定をproduct default (pollInterval 2秒、isVisible true)
    /// として復元する。
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

    /// 一覧見出しに使う名前。空ラベルを許して SSH alias へフォールバックすることで、
    /// 設定追加時に別名の入力を必須にしない。
    var displayName: String {
        let normalizedLabel = Self.trim(label)
        return normalizedLabel.isEmpty ? Self.trim(sshAlias) : normalizedLabel
    }

    /// Herdr CLI へ渡す session。空白だけの入力は「既定 session」と同じ nil にする。
    var normalizedSessionName: String? {
        Self.normalizeSessionName(sessionName)
    }

    /// 現在の入力に対応する最初のエラー。nil なら `validated()` が成功する。
    var validationError: RemoteSourceValidationError? {
        Self.validationError(for: normalized())
    }

    /// 前後空白と空 session を正規化した設定を返す。
    /// Settings から保存するときと、永続 JSON を読み戻すときの両方で呼び、
    /// 手編集された UserDefaults から危険な SSH 引数を実行経路へ渡さない。
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

    /// SSH 接続先は Process の単一 argv として渡すため、句読点を独自 grammar で
    /// 狭める必要はない。option として解釈される先頭 `-` と、複数引数や端末制御へ
    /// 見える空白・制御文字だけを拒否する。
    private static func isSafeSSHAlias(_ value: String) -> Bool {
        guard !value.hasPrefix("-") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    /// Herdr の session grammar `[A-Za-z0-9._-]+` を ASCII scalar 単位で判定する。
    /// `.` と `..` は grammar 上の文字だけで構成されるが、Herdr が予約するため除外する。
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

/// 複数 Herdr サーバに同じ pane ID が存在しても衝突しない表示 identity。
struct SourcePaneID: Hashable, Sendable {
    let sourceID: HerdrSourceID
    let paneID: String
}

/// 複数 Herdr サーバに同じ workspace ID が存在しても衝突しない表示 identity。
struct SourceWorkspaceID: Hashable, Sendable {
    let sourceID: HerdrSourceID
    let workspaceID: String
}

/// リモート接続設定の読み書きを Store から分離する依存境界。
/// `load` は保存値が無い場合、JSON が壊れている場合、または 1 件でも validation に
/// 失敗した場合に空配列へ戻す。`save` は全件を検証してから 1 個の JSON 配列として
/// 書くため、途中まで更新された設定を残さない。
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

    /// アプリ本体が使う UserDefaults 実装。保存対象は
    /// `[RemoteSourceConfiguration]` の JSON だけに限定する。
    static let live = userDefaults(.standard)

    /// テスト用 suite でも本番と同じ JSON 契約を使える UserDefaults 実装。
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

    /// @testable のテストが壊れた JSON を同じ保存場所へ注入するため internal にする。
    static let userDefaultsKey = "RemoteHerdrSources"
}
