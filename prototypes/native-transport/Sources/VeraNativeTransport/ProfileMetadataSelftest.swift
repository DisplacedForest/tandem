import Foundation
import Darwin

enum ProfileMetadataSelftest {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("vera-profile-metadata-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let file = directory.appendingPathComponent("config.json")
        let profile = UUID().uuidString
        let value: J = .object(["native_chat": .object(["activeProfileID": .string(profile), "profiles": .array([.object(["id": .string(profile), "baseURL": .string(origin), "selectedModel": .string(modelID)])])]), "unrelated_fixture": .object(["ignored": .string("not forwarded")])])
        let bytes = try value.data()
        try bytes.write(to: file)
        try ensure(chmod(file.path, 0o600) == 0)
        try SelectedProfileMetadata.validate(file, profile: profile)
        var info = stat()
        try ensure(lstat(directory.path, &info) == 0 && (info.st_mode & 0o777) == 0o755)
        try ensure(lstat(file.path, &info) == 0 && (info.st_mode & 0o777) == 0o600)
        try ensure(try Data(contentsOf: file) == bytes)
        try Selftest.expect(.storage) { _ = try PrivateFiles.read(file) }
        try ensure(chmod(directory.path, 0o700) == 0)
        try SelectedProfileMetadata.validate(file, profile: profile)
        try ensure(try PrivateFiles.read(file) == bytes)
        try ensure(chmod(directory.path, 0o755) == 0)
        for mode in [0o775, 0o757] {
            try ensure(chmod(directory.path, mode_t(mode)) == 0)
            try Selftest.expect(.storage) { try SelectedProfileMetadata.validate(file, profile: profile) }
        }
        try ensure(chmod(directory.path, 0o755) == 0)
        for mode in [0o640, 0o604] {
            try ensure(chmod(file.path, mode_t(mode)) == 0)
            try Selftest.expect(.storage) { try SelectedProfileMetadata.validate(file, profile: profile) }
        }
        try ensure(chmod(file.path, 0o600) == 0)
        let hardlink = directory.appendingPathComponent("linked.json")
        try ensure(link(file.path, hardlink.path) == 0)
        try Selftest.expect(.storage) { try SelectedProfileMetadata.validate(file, profile: profile) }
        try FileManager.default.removeItem(at: hardlink)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        try Selftest.expect(.storage) { try SelectedProfileMetadata.validate(alias.appendingPathComponent("config.json"), profile: profile) }
        let symlink = directory.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        try Selftest.expect(.storage) { try SelectedProfileMetadata.validate(symlink, profile: profile) }
        let fifo = directory.appendingPathComponent("fifo")
        try ensure(mkfifo(fifo.path, 0o600) == 0)
        try Selftest.expect(.storage) { try SelectedProfileMetadata.validate(fifo, profile: profile) }
        try Selftest.expect(.storage) { try SelectedProfileMetadata.validate(directory, profile: profile) }
        try Selftest.expect(.storage) { try SelectedProfileMetadata.validate(directory.appendingPathComponent("missing"), profile: profile) }
        try Data(repeating: 32, count: 4_000_001).write(to: file)
        try Selftest.expect(.storage) { try SelectedProfileMetadata.validate(file, profile: profile) }
        try Data("invalid JSON".utf8).write(to: file)
        try Selftest.expect { try SelectedProfileMetadata.validate(file, profile: profile) }
        try bytes.write(to: file)
        try Selftest.expect(.unauthorized) { try SelectedProfileMetadata.validate(file, profile: UUID().uuidString) }
        let settings = value["native_chat"]
        let wrong = changed(value, "native_chat", changed(settings, "profiles", .array([changed(settings["profiles"].array![0], "selectedModel", .string("another-model"))])))
        try wrong.data().write(to: file)
        try Selftest.expect(.unauthorized) { try SelectedProfileMetadata.validate(file, profile: profile) }
        try bytes.write(to: file)
        try SelectedProfileMetadata.validate(file, profile: profile)
        try ensure(lstat(directory.path, &info) == 0 && (info.st_mode & 0o777) == 0o755)
        try ensure(lstat(file.path, &info) == 0 && (info.st_mode & 0o777) == 0o600)
        try ensure(try Data(contentsOf: file) == bytes)
    }
}
