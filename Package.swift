// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shepherd",
    platforms: [
        // Window scene defaultLaunchBehavior(.suppressed) / restorationBehavior(.disabled),
        // which keep this menu-bar app from opening a window at launch, need macOS 15.
        .macOS(.v15)
    ],
    dependencies: [
        // SwiftPM only links Sparkle; the Makefile embeds it into Contents/Frameworks.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "Shepherd",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [
                // .copy, not .process: AgentIcons looks the marks up under an
                // AgentMarks/ subdirectory of Bundle.module.
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
