// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Facet",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Facet",
            path: "Sources/Facet",
            resources: [
                .copy("Resources/Models"),
                .copy("Resources/web"),
                .copy("Resources/bpe_simple_vocab_16e6.txt"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
