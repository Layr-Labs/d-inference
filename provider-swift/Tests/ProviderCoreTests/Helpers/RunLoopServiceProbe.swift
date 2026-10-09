import Foundation

/// A timer that is due at once on the run loop of the thread that creates it.
/// It fires only if something runs that run loop, which is how a test sees
/// whether a synchronous call serviced its caller's run loop.
final class RunLoopServiceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var timer: CFRunLoopTimer?

    init() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), 0, 0, 0) { [self] _ in
            lock.withLock { fired = true }
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
        self.timer = timer
    }

    var runLoopWasServiced: Bool { lock.withLock { fired } }

    func cancel() {
        if let timer { CFRunLoopTimerInvalidate(timer) }
    }
}
