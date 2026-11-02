// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Goblin",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Goblin", targets: ["Goblin"])],
    targets: [
        .executableTarget(name: "Goblin", path: "Sources"),
        .testTarget(name: "GoblinTests", dependencies: ["Goblin"], path: "Tests/Swift")
    ],
    swiftLanguageModes: [.v6]
)
