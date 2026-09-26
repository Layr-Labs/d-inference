import Foundation
@preconcurrency import DeviceCheck

/// Bounded, client-reported diagnostics. No localized descriptions, userInfo,
/// key identifiers, proof bytes or arbitrary domain strings cross the wire.
public struct AppAttestAppleError: Codable, Sendable, Equatable {
    public let domain: String
    public let code: Int
    public let underlyingDomain: String?
    public let underlyingCode: Int?

    enum CodingKeys: String, CodingKey {
        case domain, code
        case underlyingDomain = "underlying_domain"
        case underlyingCode = "underlying_code"
    }

    init(_ error: NSError) {
        domain = Self.domain(error.domain)
        code = Self.code(error.code)
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        underlyingDomain = underlying.map { Self.domain($0.domain) }
        underlyingCode = underlying.map { Self.code($0.code) }
    }

    private static func domain(_ value: String) -> String {
        switch value {
        case DCErrorDomain: return "devicecheck"
        case NSOSStatusErrorDomain: return "osstatus"
        case NSURLErrorDomain: return "url"
        case NSCocoaErrorDomain: return "cocoa"
        default: return "other"
        }
    }

    private static func code(_ value: Int) -> Int {
        Int32(exactly: value).map(Int.init) ?? 0
    }
}

struct AppleAppAttestFailure: Error, Sendable {
    let failure: ShadowFailure
    let details: AppAttestAppleError
    let chain: [AppAttestNativeErrorEntry]

    init(_ error: NSError) {
        details = AppAttestAppleError(error)
        chain = AppAttestNativeErrorChain.entries(error)
        guard error.domain == DCErrorDomain else { failure = .appleError; return }
        switch error.code {
        case DCError.Code.featureUnsupported.rawValue: failure = .unsupported
        case DCError.Code.serverUnavailable.rawValue: failure = .appleUnavailable
        case DCError.Code.invalidKey.rawValue: failure = .appleInvalidKey
        default: failure = .appleError
        }
    }
}
