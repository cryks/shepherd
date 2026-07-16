// エージェント種類 (Pane.agent) をブランドマーク画像に解決する。
// アセットは Resources/AgentMarks/<agent>-<style>.pdf のベクタで、
// ファイル名の <agent> は herdr の検出ラベル (claude, codex など) に一致させる。
// mono は黒一色塗り。表示側 (AgentRow) が template 描画で前景色に載せ替える
// 前提なので、この塗り色自体は画面に出ない。
// color はブランド色そのままの塗りで、original 描画される前提。
// どちらを使うかは設定 (colorAgentIconsKey) に従って AgentRow が選ぶ。
// アセットが無い agent 名は nil を返し、呼び出し側が従来のテキスト表示に
// フォールバックする。

import AppKit

/// マークの塗り分け。rawValue がアセットのファイル名サフィックスになる。
enum AgentIconStyle: String {
    case mono
    case color
}

@MainActor
enum AgentIcons {
    /// 解決結果のキャッシュ。アセットが無い agent も nil のまま記憶して、
    /// 行の再描画のたびに Bundle 探索が走らないようにする。
    private static var cache: [String: NSImage?] = [:]

    /// agent 名に対応するマークを返す。対応アセットが無ければ nil。
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
