// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shepherd",
    platforms: [
        // Window シーンの defaultLaunchBehavior(.suppressed) / restorationBehavior(.disabled)
        // (メニューバー常駐アプリで監視ウィンドウが起動時に勝手に開くのを防ぐ) が macOS 15 から。
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "Shepherd",
            resources: [
                // エージェント種類のブランドマーク PDF 群。AgentIcons が
                // Bundle.module の AgentMarks/ サブディレクトリとして読む。
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
