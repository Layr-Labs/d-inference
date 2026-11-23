import Foundation
import IOKit.pwr_mgt

private let messageCanSystemSleep = natural_t(0xe000_0270)
private let messageSystemWillSleep = natural_t(0xe000_0280)

/// Runs `onWillSleep` when the Mac is about to sleep and only then lets it
/// sleep, so memory released there is never part of a hibernation image.
/// Registration failure leaves sleep unaffected; the pool's other release
/// points and its TTL still apply.
final class SystemSleepRelease: @unchecked Sendable {
    private let onWillSleep: @Sendable () -> Void
    private let queue = DispatchQueue(label: "dev.darkbloom.system-sleep-release")
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(onWillSleep: @escaping @Sendable () -> Void) {
        self.onWillSleep = onWillSleep
        rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(), &notificationPort, systemSleepCallback, &notifier)
        if let notificationPort { IONotificationPortSetDispatchQueue(notificationPort, queue) }
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        if rootPort != 0 { IOServiceClose(rootPort) }
    }

    fileprivate func handle(message: natural_t, argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch message {
        case messageCanSystemSleep:
            IOAllowPowerChange(rootPort, token)
        case messageSystemWillSleep:
            onWillSleep()
            IOAllowPowerChange(rootPort, token)
        default:
            break
        }
    }
}

private let systemSleepCallback: IOServiceInterestCallback = { reference, _, messageType, messageArgument in
    guard let reference else { return }
    Unmanaged<SystemSleepRelease>.fromOpaque(reference).takeUnretainedValue()
        .handle(message: messageType, argument: messageArgument)
}
