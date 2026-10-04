// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Aki",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "aki", targets: ["Aki"])],
    // Sparkle (MIT): in-app updates from the appcast on the site, signed with Aki's own key.
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")],
    targets: [
        .target(name: "AkiCore"),
        .executableTarget(
            name: "Aki", dependencies: ["AkiCore", .product(name: "Sparkle", package: "Sparkle")],
            // Swift 5 mode: the views adapted from Codenotch were written for it.
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // No XCTest/Testing without full Xcode, so checks run as an executable: `swift run AkiChecks`.
        .executableTarget(name: "AkiChecks", dependencies: ["AkiCore"], path: "Tests/AkiChecks"),
    ]
)
