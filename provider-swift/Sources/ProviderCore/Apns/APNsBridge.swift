import Foundation

/// Bridges the macOS app delegate (which owns the APNs callbacks on the main
/// thread) and the `ProviderLoop` actor (which owns K + the SE signer + the
/// WebSocket send path).
///
/// The app delegate publishes the device token and delivers incoming pushes
/// here; the `ProviderLoop` awaits the token before registering and installs a
/// handler for incoming code-identity challenges. A process-wide singleton
/// because AppKit constructs the delegate (no DI seam) and there is exactly one
/// provider loop per process.
public final class APNsBridge: @unchecked Sendable {
    public static let shared = APNsBridge()

    private let lock = NSLock()
    private var deviceToken: String?
    private var pushHandler: (@Sendable ([String: Any]) -> Void)?
    /// Pushes that arrived before the handler was installed. A code-identity
    /// challenge can land in the window between `registerForRemoteNotifications`
    /// and `ProviderLoop` calling `setPushHandler` (and the coordinator pushes
    /// only once per connection, with no provider-side retry), so dropping one
    /// would strand the provider un-attested until the next reconnect. Buffer
    /// them (bounded) and flush when the handler arrives.
    private var pendingPushes: [[String: Any]] = []
    private let maxPendingPushes = 16

    private init() {}

    /// Called by the app delegate when APNs returns a device token (hex).
    public func setDeviceToken(_ hex: String) {
        lock.lock()
        deviceToken = hex
        lock.unlock()
    }

    /// The current device token, if APNs has returned one.
    public func currentDeviceToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return deviceToken
    }

    /// Awaits the device token, returning nil after `timeoutSeconds`. The timeout
    /// matters: a headless / no-GUI / login-screen box never gets a token, and
    /// must still register (un-attested) rather than hang at startup.
    public func awaitDeviceToken(timeoutSeconds: Double) async -> String? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let t = currentDeviceToken() { return t }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        return currentDeviceToken()
    }

    /// Installs the handler the app delegate invokes for each incoming push, then
    /// flushes any pushes that arrived before it was installed.
    public func setPushHandler(_ handler: @escaping @Sendable ([String: Any]) -> Void) {
        lock.lock()
        pushHandler = handler
        let buffered = pendingPushes
        pendingPushes.removeAll()
        lock.unlock()
        // Deliver buffered pushes outside the lock (the handler may re-enter).
        for userInfo in buffered { handler(userInfo) }
    }

    /// Called by the app delegate on didReceiveRemoteNotification.
    public func deliverPush(_ userInfo: [String: Any]) {
        lock.lock()
        if let h = pushHandler {
            lock.unlock()
            h(userInfo)
        } else {
            // No handler yet — buffer (bounded, newest-wins) so the push isn't lost.
            pendingPushes.append(userInfo)
            if pendingPushes.count > maxPendingPushes { pendingPushes.removeFirst() }
            lock.unlock()
        }
    }
}
