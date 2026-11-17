import Foundation
import OSLog

extension ChatStore {
    static let permissionFailuresBeforeNotice = 3

    var permissionQuestionsNotice: String? {
        permissionCheckFailures >= Self.permissionFailuresBeforeNotice ? RulesCopy.permissionQuestionsFailing : nil
    }

    func notePermissionCheck(_ source: NativeAuthorizationSource) {
        switch source {
        case .model:
            if permissionCheckFailures != 0 { permissionCheckFailures = 0 }
        case .remembered:
            return
        case .failed(let failure):
            guard failure != .tooLong else { return }
            permissionCheckFailures += 1
            Self.rulesLog.error("permission_check_failed \(failure.rawValue, privacy: .public)")
        }
    }
}
