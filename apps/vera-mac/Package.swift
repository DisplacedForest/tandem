// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Vera",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(path: "../../prototypes/assistant-ui"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/socketio/socket.io-client-swift", from: "16.1.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "Vera",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "VeraAssistantUI", package: "assistant-ui"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SocketIO", package: "socket.io-client-swift"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/Vera",
            resources: [.process("Resources")]
        )
    ]
)
