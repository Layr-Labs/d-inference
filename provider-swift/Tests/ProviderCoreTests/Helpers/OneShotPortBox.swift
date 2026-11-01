import Foundation

/// One-shot async box for the port a test server bound (`MockCoordinator`, `LocalCDNFileServer`).
/// `complete(_:)` is fired from Hummingbird's `onServerRunning` callback; `value` is awaited from `start()`.
final class OneShotPortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var port: Int?
    private var continuation: CheckedContinuation<Int, Never>?

    var value: Int {
        get async {
            await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
                lock.withLock {
                    if let p = port { cont.resume(returning: p) } else { continuation = cont }
                }
            }
        }
    }

    func complete(_ port: Int) {
        let cont: CheckedContinuation<Int, Never>? = lock.withLock {
            if self.port != nil { return nil }
            self.port = port
            let cont = continuation
            continuation = nil
            return cont
        }
        cont?.resume(returning: port)
    }
}
