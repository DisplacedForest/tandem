// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VeraPrototype",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VeraAssistantUI", targets: ["VeraAssistantUI"]),
        .executable(name: "VeraPrototype", targets: ["VeraPrototype"])
    ],
    targets: [
        .target(name: "VeraAssistantUI"),
        .executableTarget(name: "VeraPrototype", dependencies: ["VeraAssistantUI"])
    ]
)
