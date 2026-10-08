import Foundation

/// One serialized host-control operation. No resource observation is stored.
/// Entry/exit perform independent fresh admission. The borrowed inner checker
/// retains native-fault/deadline/lifecycle checks, never resource authority.
final class BoundedControlResourceOperation {
    enum Failure: Error, Equatable { case reused, cancelled, closed, reentered }
    private enum Phase: Equatable { case fresh, running, completed, failed }
    private var phase = Phase.fresh
    private var active: Checkpoint?

    final class Checkpoint {
        private weak var owner: BoundedControlResourceOperation?
        private var callback: (() throws -> Void)?
        private var checking = false

        fileprivate init(owner: BoundedControlResourceOperation, callback: @escaping () throws -> Void) {
            self.owner = owner; self.callback = callback
        }
        fileprivate func close() { callback = nil; owner = nil }

        func check() throws {
            guard let owner, owner.phase == .running, let callback else { throw Failure.closed }
            guard !checking else { owner.cancel(); throw Failure.reentered }
            checking = true; defer { checking = false }
            do {
                try callback()
                guard owner.phase == .running, self.callback != nil else { throw Failure.cancelled }
            } catch { owner.cancel(); throw error }
        }
    }

    func cancel() {
        phase = .failed; active?.close(); active = nil
    }

    func send(resourceCheck: () throws -> Void, faultCheck: () throws -> Void,
              body: (Checkpoint) throws -> Void) throws {
        try perform(resourceCheck: resourceCheck, faultCheck: faultCheck, body: body)
    }

    func receive(resourceCheck: () throws -> Void, faultCheck: () throws -> Void,
                 body: (Checkpoint) throws -> Data) throws -> Data {
        try perform(resourceCheck: resourceCheck, faultCheck: faultCheck, body: body)
    }

    private func perform<T>(resourceCheck: () throws -> Void, faultCheck: () throws -> Void,
                            body: (Checkpoint) throws -> T) throws -> T {
        guard phase == .fresh else { cancel(); throw Failure.reused }
        phase = .running
        do {
            // This finishes its fresh observation before any caller allocation.
            try resourceCheck()
            guard phase == .running else { throw Failure.cancelled }
            let result = try withoutActuallyEscaping(faultCheck) { borrowed in
                let checkpoint = Checkpoint(owner: self, callback: borrowed)
                active = checkpoint
                defer { checkpoint.close(); active = nil }
                let value = try body(checkpoint)
                guard phase == .running else { throw Failure.cancelled }
                // Invalidate before exit admission. Even an escaped checkpoint
                // cannot run again or retain the borrowed error-context closure.
                checkpoint.close(); active = nil
                try resourceCheck()
                guard phase == .running else { throw Failure.cancelled }
                return value
            }
            phase = .completed
            return result
        } catch { cancel(); throw error }
    }

    deinit { cancel() }
}
