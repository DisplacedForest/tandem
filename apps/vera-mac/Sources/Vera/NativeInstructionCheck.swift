import Foundation

enum NativeInstructionCheck {
    static let targetLimit = 300
    static let saidLimit = 2_000

    static func clean(_ value: String) -> String {
        let flat = value.unicodeScalars.map { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(flat.trimmingCharacters(in: .whitespaces).prefix(targetLimit))
    }
}
