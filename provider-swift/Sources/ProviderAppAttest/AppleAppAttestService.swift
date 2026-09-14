import Foundation
import Security
@preconcurrency import DeviceCheck

/// Uses public DeviceCheck APIs. No private entitlements or OS bypasses.
public actor AppleAppAttestService: AppAttestService {
    public init() {}
    private var operationPending = false
    private func finishOperation() { operationPending = false }

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
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { throw ShadowFailure.notConfigured }
        try AppAttestEntitlementPolicy.validate(entitlements, expectedEnvironment: environment)
        guard DCAppAttestService.shared.isSupported else { throw ShadowFailure.unsupported }
    }

    public func generateKey() async throws -> String {
        guard !operationPending else { throw ShadowFailure.busy }
        operationPending = true
        return try await CallbackDeadline<String>.call { complete in
            DCAppAttestService.shared.generateKey { value, error in
                Task { await self.finishOperation() }
                if let value { complete(.success(value)) }
                else { complete(.failure(Self.failure(error))) }
            }
        }
    }

    public func attestKey(_ id: String, hash: Data) async throws -> Data {
        guard !operationPending else { throw ShadowFailure.busy }
        operationPending = true
        return try await CallbackDeadline<Data>.call { complete in
            DCAppAttestService.shared.attestKey(id, clientDataHash: hash) { value, error in
                Task { await self.finishOperation() }
                if let value { complete(.success(value)) }
                else { complete(.failure(Self.failure(error))) }
            }
        }
    }

    public func generateAssertion(_ id: String, hash: Data) async throws -> Data {
        guard !operationPending else { throw ShadowFailure.busy }
        operationPending = true
        return try await CallbackDeadline<Data>.call { complete in
            DCAppAttestService.shared.generateAssertion(id, clientDataHash: hash) { value, error in
                Task { await self.finishOperation() }
                if let value { complete(.success(value)) }
                else { complete(.failure(Self.failure(error))) }
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
