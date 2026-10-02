import Foundation
import Darwin

/// One nonblocking pipe reader. EOF is diagnostic completeness only; it is
/// never evidence of native retirement or authenticated owner lease release.
final class ClusterOwnerDiagnostics: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var bytes = Data()
    private var reachedEOF = false
    private var failed = false
    static let maximumBytes = 1_048_576

    init(descriptor: Int32) { self.descriptor = descriptor }
    var snapshot: Data { lock.withLock { bytes } }
    var isComplete: Bool { lock.withLock { reachedEOF && !failed } }
    private var isTerminal: Bool { lock.withLock { reachedEOF || failed } }

    /// At most one bounded read; false also covers a temporarily empty pipe.
    @discardableResult
    func readAvailable() throws -> Bool {
        guard !isTerminal else { return false }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 {
            try lock.withLock {
                guard bytes.count <= Self.maximumBytes - count else {
                    failed = true
                    throw OwnerWire.invalid("SSH stderr exceeded bound")
                }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            return true
        }
        if count == 0 { lock.withLock { reachedEOF = true }; return false }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return false }
        lock.withLock { failed = true }
        throw OwnerWire.invalid("SSH stderr read failed")
    }

    /// Retain buffered bytes after transport exit. A leaked writer or a read
    /// error leaves isComplete false; neither extends the supplied deadline.
    func drain(until deadline: UInt64) {
        repeat {
            do {
                let madeProgress = try readAvailable()
                if isTerminal { return }
                if !madeProgress {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadline else { return }
                    Thread.sleep(forTimeInterval: min(0.005, Double(deadline - now) / 1_000_000_000))
                }
            } catch { return }
        } while DispatchTime.now().uptimeNanoseconds < deadline
    }
}
