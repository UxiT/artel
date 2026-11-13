// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Artel",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Artel", targets: ["Artel"]),
        .executable(name: "artel-hook", targets: ["ArtelHook"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.99.0"),
        // Markdown preview. Its successor Textual needs SwiftUI macros that ship only with Xcode.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        // TextKit 2 text editor for task descriptions and project docs.
        .package(url: "https://github.com/krzyzanowskim/STTextView", from: "2.4.0"),
        // Self-update from GitHub releases (appcast + EdDSA-signed zip).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(name: "ArtelCore"),
        .executableTarget(name: "ArtelHook", dependencies: ["ArtelCore"]),
        .executableTarget(
            name: "Artel",
            dependencies: [
                "ArtelCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "STTextView", package: "STTextView"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ArtelCoreTests", dependencies: ["ArtelCore"]),
    ]
)
