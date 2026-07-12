import Foundation
import IOKit.pwr_mgt

private let messageCanSystemSleep = natural_t(0xe000_0270)
private let messageSystemWillSleep = natural_t(0xe000_0280)
private let messageSystemHasPoweredOn = natural_t(0xe000_0300)

enum FanPowerMonitorError: Error {
    case registrationFailed
}

final class FanPowerMonitor {
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let daemon: FanDaemon

    init(daemon: FanDaemon) throws {
        self.daemon = daemon
        rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &notificationPort,
            fanPowerCallback,
            &notifier
        )
        guard rootPort != 0,
              let notificationPort,
              let source = IONotificationPortGetRunLoopSource(notificationPort)?
                .takeUnretainedValue()
        else {
            throw FanPowerMonitorError.registrationFailed
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
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
            Task { [daemon, rootPort] in
                await daemon.prepareForSleep()
                IOAllowPowerChange(rootPort, token)
            }
        case messageSystemHasPoweredOn:
            Task { [daemon] in await daemon.didWake() }
        default:
            break
        }
    }
}

private let fanPowerCallback: IOServiceInterestCallback = {
    reference, _, messageType, messageArgument in
    guard let reference else { return }
    let monitor = Unmanaged<FanPowerMonitor>
        .fromOpaque(reference)
        .takeUnretainedValue()
    monitor.handle(message: messageType, argument: messageArgument)
}
