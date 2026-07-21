// Content of the About window scene. Owns the scene ID, the GitHub repository
// link, and how the app presents itself: icon, name, and version. The name is
// a fixed string; the version comes from the main bundle's Info.plist. The
// scene itself is declared by ShepherdApp and opens only from MenuPanel's
// "About Shepherd" item.

import AppKit
import SwiftUI

/// Scene ID of the About window. Referenced by openWindow in MenuPanel.
let aboutWindowId = "about"

/// OSS-style About panel: app icon, name, version, and a link to the GitHub
/// repository. The hosting Window scene uses windowResizability(.contentSize),
/// so the fixed width here and the intrinsic height determine the window size.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            // NSApp.applicationIconImage resolves CFBundleIconFile inside the
            // .app; the bare build product falls back to the generic app icon.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text(verbatim: "Shepherd")
                .font(.title2.weight(.semibold))
                .padding(.top, 8)
            Text(tr("Version \(appVersion)", ja: "バージョン \(appVersion)"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)
            Link(destination: repositoryURL) {
                Text(verbatim: "GitHub")
            }
            .font(.subheadline)
            .padding(.top, 12)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 300)
    }

    private let repositoryURL = URL(string: "https://github.com/cryks/shepherd")!

    /// Running the bare build product outside the .app (no Info.plist) yields
    /// the "-" placeholder.
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "-"
    }
}
