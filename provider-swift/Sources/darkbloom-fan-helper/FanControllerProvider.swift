import FanControlCore
import Foundation

final class FanControllerProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var loadedController: FanLeaseController?

    func controller() throws -> FanLeaseController {
        try lock.withLock {
            if let loadedController {
                return loadedController
            }
            let controller = try FanLeaseController()
            loadedController = controller
            return controller
        }
    }

    func prepare() {
        do {
            _ = try controller()
        } catch {
            log("hardware is not ready: \(error.localizedDescription)")
        }
    }

    func cancelLeaseIfLoaded(_ id: UUID) {
        let controller = lock.withLock { loadedController }
        controller?.cancelLease(id)
    }

    func shutdown() throws {
        try lock.withLock {
            try loadedController?.shutdown()
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(
            Data(("fan-helper: \(message)\n").utf8)
        )
    }
}
