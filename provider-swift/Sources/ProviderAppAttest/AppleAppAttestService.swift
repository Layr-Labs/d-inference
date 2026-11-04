import Foundation
import Security
@preconcurrency import DeviceCheck

/// Uses public DeviceCheck APIs. No private entitlements or OS bypasses.
public actor AppleAppAttestService: AppAttestService {
    private let callbacks: any AppAttestCallbacks
    private let operationTimeout: Double
    private let operations: AppleOperationGate
    private let support: AppAttestSupport
    /// Set by the first unsupported answer, so a service re-registers its bundle
    /// at most once. A provider without an availability schedule keeps one
    /// service per process. A scheduled provider makes a new one for each
    /// availability window, so it can re-register once per window.
    private var registrationRefreshed = false

    public init() {
        callbacks = SystemAppAttestCallbacks()
        operationTimeout = 25
        operations = AppleOperationGate()
        support = .system
    }

    init(callbacks: any AppAttestCallbacks, operationTimeout: Double, support: AppAttestSupport = .system,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.callbacks = callbacks
        self.operationTimeout = operationTimeout
        self.support = support
        operations = AppleOperationGate(now: now)
    }

    /// Live `DCAppAttestService.isSupported` alone. The restart for an
    /// unsupported state reads it again before and after its drain, because
    /// the state can clear inside the same process.
    public static func isSupportedNow() -> Bool {
        DCAppAttestService.shared.isSupported
    }

    public func operationHeldSince() -> Date? {
        operations.heldSince
    }

    public func checkAvailability(environment: String) throws {
        try AppAttestAvailabilityChecks.requireOS(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        try AppAttestAvailabilityChecks.requireAppBundle(Bundle.main.bundleURL.pathExtension)
        let values = try AppAttestAvailabilityChecks.requireSigningInfo(AppAttestSigningInfo.current())
        // A successful signing-info query without an entitlement dictionary
        // means the required opt-in is absent, not that the query failed.
        let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        try AppAttestEntitlementPolicy.validateAvailability(entitlements, expectedEnvironment: environment)
        try AppAttestAvailabilityChecks.requireSupported(isSupportedRefreshingRegistration(app: Bundle.main.bundleURL))
    }

    /// Apple's answer. On this service's first unsupported answer it
    /// re-registers `app` with LaunchServices and asks again, so a record left
    /// stale by a self-update does not fail the exchange (`AppAttestSupport`).
    func isSupportedRefreshingRegistration(app: URL) -> Bool {
        if support.isSupported() { return true }
        guard !registrationRefreshed else { return false }
        registrationRefreshed = true
        support.refreshRegistration(app)
        return support.isSupported()
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
