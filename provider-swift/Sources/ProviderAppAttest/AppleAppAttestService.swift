import Foundation
import Security
@preconcurrency import DeviceCheck

/// Uses public DeviceCheck APIs. No private entitlements or OS bypasses.
public actor AppleAppAttestService: AppAttestService {
    public init() {}

    public func checkAvailability(environment: String) throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { throw ShadowFailure.unsupported }
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw ShadowFailure.notConfigured }
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let configured = entitlements["com.apple.developer.devicecheck.appattest-environment"] as? String
        else { throw ShadowFailure.notConfigured }
        guard configured == environment else { throw ShadowFailure.environmentMismatch }
        guard DCAppAttestService.shared.isSupported else { throw ShadowFailure.unsupported }
    }

    public func generateKey() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateKey { value, error in
                if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: Self.failure(error)) }
            }
        }
    }

    public func attestKey(_ id: String, hash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.attestKey(id, clientDataHash: hash) { value, error in
                if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: Self.failure(error)) }
            }
        }
    }

    public func generateAssertion(_ id: String, hash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DCAppAttestService.shared.generateAssertion(id, clientDataHash: hash) { value, error in
                if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: Self.failure(error)) }
            }
        }
    }

    private static func failure(_ error: Error?) -> ShadowFailure {
        guard let error = error as NSError?, error.domain == DCErrorDomain else { return .appleError }
        switch error.code {
        case DCError.Code.featureUnsupported.rawValue: return .unsupported
        case DCError.Code.serverUnavailable.rawValue: return .appleUnavailable
        case DCError.Code.invalidKey.rawValue: return .appleInvalidKey
        default: return .appleError
        }
    }
}
