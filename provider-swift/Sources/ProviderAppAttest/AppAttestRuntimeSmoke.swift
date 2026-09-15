import Dispatch
import Foundation

/// Exercises real deadline completion and expiry inside the fully linked release
/// executable. No DeviceCheck request, Keychain access, or provider connection.
/// Debug-only unit tests do not detect the cross-module optimized sleep crash.
public enum AppAttestRuntimeSmoke {
    public static let successMarker = "app-attest-callback-runtime-smoke: ok"

    public static func run() async throws {
        // A successful callback cancels its sleeping deadline. Repetition catches
        // the original asynchronous cleanup failure after the callback returned.
        for _ in 0..<64 {
            let value: Int = try await CallbackDeadline.call(seconds: 1) { complete in
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(1)) {
                    complete(.success(1))
                }
            }
            guard value == 1 else { throw SmokeFailure.unexpectedResult }
        }
        do {
            let _: Int = try await CallbackDeadline.call(seconds: 0.01) { _ in }
            throw SmokeFailure.deadlineDidNotFire
        } catch ShadowFailure.operationTimeout {
            // Expiry is the other cleanup path of the same real deadline task.
        }
    }

    private enum SmokeFailure: Error {
        case unexpectedResult, deadlineDidNotFire
    }
}
