// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Drott",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Drott",
            path: "Sources/Drott",
            resources: [.process("pieces"), .copy("models")]
        )
    ]
)
