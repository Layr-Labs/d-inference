import Foundation
import Darwin

/// One coalesced, nonblocking notification for a single poll-owner thread.
/// The pump owns the read descriptor until it leaves its poll loop. Only that
/// thread may call closeAfterPolling(); deinit handles a never-launched owner.
final class WorkerPumpWakeup: @unchecked Sendable {
    private let lock = NSLock()
    let readDescriptor: Int32
    private let writeDescriptor: Int32
    private var pending = false
    private var closed = false

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else { throw ClusterWorkerOwnerError.invalid("Cannot create pump wakeup") }
        var complete = false
        defer { if !complete { for descriptor in descriptors { Darwin.close(descriptor) } } }
        for descriptor in descriptors {
            guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw ClusterWorkerOwnerError.invalid("Cannot bound pump wakeup")
            }
        }
        guard fcntl(descriptors[1], F_SETNOSIGPIPE, 1) == 0 else {
            throw ClusterWorkerOwnerError.invalid("Cannot suppress pump wakeup SIGPIPE")
        }
        readDescriptor = descriptors[0]; writeDescriptor = descriptors[1]; complete = true
    }

    /// No lock held by the poll wait. Signal/close serialize the descriptor use,
    /// so a late signal cannot write to an unrelated FD reusing the old number.
    /// Four interrupted nonblocking attempts are bounded; the unchanged poll
    /// timeout remains a fallback if all attempts receive EINTR.
    @discardableResult func signal() -> Bool {
        lock.withLock {
            guard !closed else { return false }
            if pending { return true }
            var byte: UInt8 = 1
            for _ in 0..<4 {
                let count = Darwin.write(writeDescriptor, &byte, 1)
                if count == 1 || (count < 0 && errno == EAGAIN) { pending = true; return true }
                if count < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    /// At most one byte is queued by this object, independent of producer count.
    func drain() -> Bool {
        lock.withLock {
            guard !closed else { return false }
            var byte: UInt8 = 0
            for _ in 0..<4 {
                let count = Darwin.read(readDescriptor, &byte, 1)
                if count == 1 || (count < 0 && errno == EAGAIN) { pending = false; return true }
                if count < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    /// Caller has stopped polling this read FD. No external fence closes it.
    func closeAfterPolling() {
        lock.withLock {
            guard !closed else { return }
            closed = true; pending = false
            // Do not retry close after EINTR: the number may already be reused.
            Darwin.close(writeDescriptor); Darwin.close(readDescriptor)
        }
    }
    deinit { closeAfterPolling() }
}
