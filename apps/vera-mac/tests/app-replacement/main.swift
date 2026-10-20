import Foundation
import Darwin

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args[0] == "archive" {
        try AppUpdateArchive.validate(URL(fileURLWithPath: args[1]))
    } else if args[0] == "extract" {
        try AppUpdateArchive.extract(URL(fileURLWithPath: args[1]), to: URL(fileURLWithPath: args[2]))
    } else if args[0] == "validate" {
        try SafeAppReplacement.validateSignature(URL(fileURLWithPath: args[1]),
                                                args.count > 2 ? URL(fileURLWithPath: args[2]) : nil)
    } else if args[0] == "inspect" {
        let url = URL(fileURLWithPath: args[1])
        let receipt = try JSONDecoder().decode(AppReplacementReceipt.self, from: Data(contentsOf: url))
        print(try receipt.state(at: url).rawValue)
    } else if args[0] == "rollback" {
        print(try SafeAppReplacement.rollback(receiptURL: URL(fileURLWithPath: args[1])).path)
    } else {
        let mode = args[0]
        var hooks = SafeAppReplacement.Hooks()
        if mode != "real" { hooks.validateSignature = { _, _ in } }
        if mode == "reject-signature" {
            hooks.validateSignature = { _, _ in throw AppReplacementError("Fixture rejected signature") }
        }
        if mode == "copy-failure" || mode == "kill-copy" {
            hooks.copy = { _, destination in
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Data("partial".utf8).write(to: destination.appendingPathComponent("partial"))
                if mode == "kill-copy" {
                    try Data().write(to: URL(fileURLWithPath: args[5]))
                    raise(SIGSTOP)
                }
                throw AppReplacementError("Fixture interrupted copy")
            }
        }
        hooks.checkpoint = { phase in
            if mode == "fail-" + phase { throw AppReplacementError("Fixture checkpoint failure") }
            if mode == "kill-" + phase {
                try Data().write(to: URL(fileURLWithPath: args[5]))
                raise(SIGSTOP)
            }
            if mode == "swap-failure", phase == "prepared" {
                let directory = URL(fileURLWithPath: args[2]).deletingLastPathComponent()
                for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    where file.lastPathComponent.hasPrefix(".Vera-replacement-") {
                    try FileManager.default.removeItem(at: file.appendingPathComponent(URL(fileURLWithPath: args[2]).lastPathComponent))
                }
            }
        }
        let identifier = args.count > 6 ? args[6] : "app.vera.mac"
        let receipt = try SafeAppReplacement.replace(source: URL(fileURLWithPath: args[1]),
            target: URL(fileURLWithPath: args[2]), version: args[3], identifier: identifier,
            allowFirstInstall: args[4] == "first", hooks: hooks)
        print(receipt.path)
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
