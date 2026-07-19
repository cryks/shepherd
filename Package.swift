// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shepherd",
    platforms: [
        // defaultLaunchBehavior(.suppressed) / restorationBehavior(.disabled) on Window scenes
        // (prevents the monitoring window of this menu-bar-resident app from opening on its own
        // at launch) requires macOS 15.
        .macOS(.v15)
    ],
    dependencies: [
        // Sparkle drives in-app updates. SwiftPM only links the framework;
        // the Makefile embeds it into Contents/Frameworks of the .app.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "Shepherd",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                // Brand-mark PDFs for each agent kind. AgentIcons reads them
                // from the AgentMarks/ subdirectory of Bundle.module.
                .copy("Resources/AgentMarks")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "ShepherdTests",
            dependencies: ["Shepherd"]
        )
    ]
)
