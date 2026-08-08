import AppKit
import SwiftUI

let aboutWindowId = "about"

// The hosting Window scene uses windowResizability(.contentSize), so this
// width and the intrinsic height decide the window size.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            // Resolves CFBundleIconFile inside the .app; the bare build
            // product gets the generic app icon instead.
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

    // The bare build product runs without an Info.plist, hence the placeholder.
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "-"
    }
}
