import Foundation
import Darwin
import DarkbloomClusterProcess

/// Private qualification diagnostics. Never participates in worker or lease protocol.
final class OwnerNativeDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var child: ClusterWorkerProcess?

    func remember(_ value: ClusterWorkerProcess) {
        lock.withLock { child = value }
    }

    func encodedObservation() -> Data? {
        let value = lock.withLock { child }
        return Self.encode(constructed: value != nil, rank: value?.rank,
            pid: value?.launchedProcessIdentifier, terminal: value?.termination,
            cleanupObserved: value?.nativeCleanupObserved ?? false,
            diagnosticTail: value?.diagnosticTail ?? Data())
    }

    static func encode(constructed: Bool, rank: Int?, pid: Int32?,
                       terminal: ClusterWorkerProcessTermination?, cleanupObserved: Bool,
                       diagnosticTail: Data) -> Data? {
        let tail = Data(diagnosticTail.suffix(4096))
        var termination: [String: Any]?
        switch terminal {
        case .launchFailed: termination = ["kind": "launchFailed"]
        case .exited(let status): termination = ["kind": "exited", "status": status]
        case .signalled(let signal): termination = ["kind": "signalled", "signal": signal]
        case nil: break
        }
        let record: [String: Any] = [
            "schema": "qwen27b_owner_native_diagnostic_v1",
            "emittedAfterServiceReturnedOrThrew": true,
            "childConstructed": constructed, "rank": rank.map { $0 as Any } ?? NSNull(),
            "launchedPID": pid.map { $0 as Any } ?? NSNull(),
            "termination": termination.map { $0 as Any } ?? NSNull(),
            "nativeCleanupObserved": cleanupObserved,
            "diagnosticTailBase64": tail.base64EncodedString(),
            "diagnosticTailBytes": tail.count,
            "diagnosticTailTruncated": diagnosticTail.count > tail.count
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]),
              data.count < 8192 else { return nil }
        data.append(10)
        return data
    }

    func publish() {
        guard let data = encodedObservation() else { return }
        _ = Self.writeBounded(data, descriptor: STDERR_FILENO)
    }

    /// Best effort, at most 8 KiB/250 ms. No signal, protocol, or exit-status change.
    static func writeBounded(_ data: Data, descriptor: Int32) -> Bool {
        guard !data.isEmpty, data.count <= 8192 else { return false }
        let fd = Darwin.dup(descriptor)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let flags = fcntl(fd, F_GETFL), noPipeSignal = fcntl(fd, F_GETNOSIGPIPE)
        guard flags >= 0, noPipeSignal >= 0 else { return false }
        defer {
            _ = fcntl(fd, F_SETFL, flags)
            _ = fcntl(fd, F_SETNOSIGPIPE, noPipeSignal)
        }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { return false }
        let until = DispatchTime.now().uptimeNanoseconds + 250_000_000
        var offset = 0
        while offset < data.count, DispatchTime.now().uptimeNanoseconds < until {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count; continue }
            if count < 0, errno == EINTR { continue }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
            var writable = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < until else { return false }
            let remaining = Int32(min(25, (until - now + 999_999) / 1_000_000))
            let status = Darwin.poll(&writable, 1, remaining)
            if status < 0, errno != EINTR { return false }
        }
        return offset == data.count
    }
}
