import Foundation
import Darwin

do {
    let args = Array(CommandLine.arguments.dropFirst())
    let result: URL
    if args.count == 2, args[0] == "--rollback" {
        result = try SafeAppReplacement.rollback(receiptURL: URL(fileURLWithPath: args[1]))
    } else if args.count == 2, args[0] == "--inspect" {
        let url = URL(fileURLWithPath: args[1])
        let receipt = try JSONDecoder().decode(AppReplacementReceipt.self, from: Data(contentsOf: url))
        print(try receipt.state(at: url).rawValue)
        exit(0)
    } else {
        guard args.count == 3 || (args.count == 4 && args[3] == "--first-install") else {
            throw AppReplacementError("Usage: app-replacement SOURCE.app TARGET.app VERSION [--first-install] | --inspect RECEIPT | --rollback RECEIPT")
        }
        result = try SafeAppReplacement.replace(source: URL(fileURLWithPath: args[0]),
            target: URL(fileURLWithPath: args[1]), version: args[2], allowFirstInstall: args.count == 4)
    }
    print(result.path)
} catch {
    FileHandle.standardError.write(Data("App replacement failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
