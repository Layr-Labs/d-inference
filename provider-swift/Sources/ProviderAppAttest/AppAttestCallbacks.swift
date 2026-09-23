import Foundation
@preconcurrency import DeviceCheck

/// Callback boundary allows the adapter's timeout and recovery to be tested
/// without contacting Apple or requiring a signed macOS 27 app.
protocol AppAttestCallbacks: Sendable {
    func generateKey(_ complete: @escaping @Sendable (Result<String, Error>) -> Void)
    func attestKey(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void)
    func generateAssertion(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void)
}

struct SystemAppAttestCallbacks: AppAttestCallbacks {
    func generateKey(_ complete: @escaping @Sendable (Result<String, Error>) -> Void) {
        DCAppAttestService.shared.generateKey { value, error in
            if let value { complete(.success(value)) }
            else { complete(.failure(Self.failure(error))) }
        }
    }

    func attestKey(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) {
        DCAppAttestService.shared.attestKey(id, clientDataHash: hash) { value, error in
            if let value { complete(.success(value)) }
            else { complete(.failure(Self.failure(error))) }
        }
    }

    func generateAssertion(_ id: String, hash: Data, complete: @escaping @Sendable (Result<Data, Error>) -> Void) {
        DCAppAttestService.shared.generateAssertion(id, clientDataHash: hash) { value, error in
            if let value { complete(.success(value)) }
            else { complete(.failure(Self.failure(error))) }
        }
    }

    static func failure(_ error: Error?) -> any Error {
        guard let error = error as NSError? else { return AppAttestAppleErrorSource.callbackWithoutNSError }
        return AppleAppAttestFailure(error)
    }
}
