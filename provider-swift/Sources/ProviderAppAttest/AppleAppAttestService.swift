import Foundation
import Security
@preconcurrency import DeviceCheck

/// Uses public DeviceCheck APIs. No private entitlements or OS bypasses.
public actor AppleAppAttestService: AppAttestService {
    private let callbacks: any AppAttestCallbacks
    private let operationTimeout: Double
    private let operations = AppleOperationGate()

    public init() {
        callbacks = SystemAppAttestCallbacks()
        operationTimeout = 25
    }

    init(callbacks: any AppAttestCallbacks, operationTimeout: Double) {
        self.callbacks = callbacks
        self.operationTimeout = operationTimeout
    }

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
        try await perform { [callbacks] complete in
            callbacks.generateKey(complete)
        }
    }

    public func attestKey(_ id: String, hash: Data) async throws -> Data {
        try await perform { [callbacks] complete in
            callbacks.attestKey(id, hash: hash, complete: complete)
        }
    }

    public func generateAssertion(_ id: String, hash: Data) async throws -> Data {
        try await perform { [callbacks] complete in
            callbacks.generateAssertion(id, hash: hash, complete: complete)
        }
    }

    private func perform<Value: Sendable>(
        start: @escaping @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        return try await CallbackDeadline.call(seconds: operationTimeout) { [operations] complete in
            // Acquire only after the deadline installs its continuation: an
            // already-cancelled waiter must not strand admission without a call.
            guard let token = operations.acquire() else {
                complete(.failure(ShadowFailure.busy))
                return
            }
            start { result in
                operations.finish(token)
                complete(result)
            }
        }
    }
}
