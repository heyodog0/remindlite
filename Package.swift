// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemindLite",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "RemindLite",
            path: "Sources/RemindLite"
        )
    ],
    // Match MenuLite: Swift 6 compiler, Swift 5 language mode so the AppKit /
    // EventKit completion-handler bits stay clean and readable.
    swiftLanguageModes: [.v5]
)
