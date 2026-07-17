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
    targets: [
        .executableTarget(
            name: "Shepherd",
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
