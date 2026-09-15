import Foundation

/// Exercises real deadline completion and expiry inside the fully linked release
/// executable. No DeviceCheck request, Keychain access, or provider connection.
/// Debug-only unit tests do not detect the cross-module optimized sleep crash.
public enum AppAttestRuntimeSmoke {
    public static let successMarker = "app-attest-callback-runtime-smoke: ok"

    public static func run() async throws {
        // Complete synchronously, before installing the timer. This deterministically
        // exercises completion/cancellation without racing a queued utility callback
        // against a wall-clock deadline on a busy installer or CI host.
        for _ in 0..<64 {
            let value: Int = try await CallbackDeadline.call(seconds: 0) { complete in
                complete(.success(1))
            }
            guard value == 1 else { throw SmokeFailure.unexpectedResult }
            do {
                // No callback competes with expiry. Await the actual runtime sleep
                // and its cleanup; scheduling delays cannot cause a false failure.
                let _: Int = try await CallbackDeadline.call(seconds: 0.01) { _ in }
                throw SmokeFailure.deadlineDidNotFire
            } catch ShadowFailure.operationTimeout {
                // Expected: the fully linked deadline task ran to completion.
            }
        }
    }

    private enum SmokeFailure: Error {
        case unexpectedResult, deadlineDidNotFire
    }
}
