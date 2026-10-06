// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VeraNativeTransport",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(name: "VeraNativeTransport", dependencies: ["CSQLite"])
    ]
)
