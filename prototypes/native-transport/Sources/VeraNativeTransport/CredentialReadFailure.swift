import Security

struct CredentialReadFailure: Error, Sendable {
    let status: OSStatus
    var category: String {
        switch status {
        case errSecSuccess: return "invalid_data"
        case errSecItemNotFound: return "item_missing"
        case errSecInteractionNotAllowed: return "interaction_disallowed"
        case errSecInteractionRequired: return "interaction_required"
        case errSecMissingEntitlement: return "missing_entitlement"
        case errSecAuthFailed: return "auth_failed"
        case OSStatus(CSSMERR_CSP_OPERATION_AUTH_DENIED), OSStatus(CSSMERR_DL_OPERATION_AUTH_DENIED): return "authorization_denied"
        case errSecUserCanceled: return "canceled"
        case errSecNotAvailable: return "unavailable"
        case errSecDecode: return "decode_failed"
        default: return "os_error"
        }
    }
}
