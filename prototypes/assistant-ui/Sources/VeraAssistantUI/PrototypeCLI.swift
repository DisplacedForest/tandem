import Foundation
import SwiftUI

@MainActor
public enum AssistantPrototypeCLI {
    public static func run(arguments: [String] = CommandLine.arguments) async {
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        if arguments.contains("--selftest") {
            await PrototypeSelfTest.run()
        } else if let dataRoot = argument("--data-root") {
            do {
                let endpoint = argument("--endpoint").flatMap(URL.init(string:))
                if argument("--endpoint") != nil && endpoint == nil { throw PrototypeError.configuration }
                let configuration = try PrototypeConfiguration(
                    dataRoot: URL(fileURLWithPath: dataRoot, isDirectory: true),
                    endpoint: endpoint,
                    workspaceRoot: argument("--workspace-root").map { URL(fileURLWithPath: $0, isDirectory: true) })
                if arguments.contains("--recovery-contract-test") {
                    try await BridgeContractTest.recover(configuration: configuration)
                } else if arguments.contains("--contract-test") {
                    try await BridgeContractTest.run(configuration: configuration)
                } else if let directory = argument("--snapshot-dir") {
                    let store = try PrototypeStore(configuration: configuration)
                    await store.refresh()
                    guard store.capabilities?.transport == "mock", store.connectionError == nil else { throw PrototypeError.unavailable }
                    try RenderTest.render(store, directory: URL(fileURLWithPath: directory, isDirectory: true))
                } else {
                    let store = try PrototypeStore(configuration: configuration)
                    PrototypeApplication.launchStore = store
                    PrototypeApplication.main()
                }
            } catch {
                print(error.localizedDescription)
                exit(1)
            }
        } else {
            print("Usage: VeraPrototype --data-root <separate-folder> [--endpoint <loopback-url>] [--workspace-root <artifact-folder>]")
            exit(1)
        }
    }
}
