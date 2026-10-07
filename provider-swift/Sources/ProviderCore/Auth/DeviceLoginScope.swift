import Foundation

/// Response from POST /v1/device/code
struct DeviceCodeResponse: Decodable, Sendable {
    let device_code: String
    let user_code: String
    let verification_uri: String
    let expires_in: Int
    let interval: Int
    let purpose: String?
}

/// Response from POST /v1/device/token
struct DeviceTokenResponse: Decodable, Sendable {
    let status: String?
    let token: String?
    let purpose: String?
    let error: TokenError?

    struct TokenError: Decodable, Sendable {
        let message: String?
    }
}

// Scope is negotiated before opening the browser; an account login never replaces the
// provider's AuthTokenStore, even on coordinators that only implement provider device grants.
enum DeviceLoginScope {
    case provider, desktopAccount, legacyAccount

    static func negotiate(purpose: String?, response: DeviceCodeResponse,
                          allowLegacyAccountFlow: Bool) throws -> Self {
        guard purpose != nil else { return .provider }
        if response.purpose == "desktop_account", response.device_code.hasPrefix("desktop-account-") {
            return .desktopAccount
        }
        if allowLegacyAccountFlow, [nil, "provider"].contains(response.purpose),
           !response.device_code.hasPrefix("desktop-account-") {
            return .legacyAccount
        }
        throw DeviceAuthError.authorizationFailed("This coordinator does not support desktop account sign-in yet.")
    }

    func validate(token: String, purpose: String?) throws {
        switch self {
        case .provider: break
        case .desktopAccount:
            guard purpose == "desktop_account", token.hasPrefix("darkbloom-at-") else {
                throw DeviceAuthError.invalidResponse("wrong account token scope")
            }
        case .legacyAccount:
            guard [nil, "provider"].contains(purpose), token.hasPrefix("eigeninference-pt-") else {
                throw DeviceAuthError.invalidResponse("wrong legacy account token scope")
            }
        }
    }
}

