import Foundation

/// Dev and DevNet installs only: a one-shot fault that makes this rank's
/// memory read as taken, for proving on real Macs that a refusal ends that
/// request alone (D6). It changes nothing but the reading. From the armed
/// request's Nth pass of the host memory gate on (`QwenDenseStageLoadWatch.admits`),
/// the gate judges its sample as this Mac would read once another process
/// had taken its free pages and its file cache (`withMemoryTaken`). The
/// policy refuses that sample with its own sentence, and the first check that
/// judges it throws, as it would for a real reading: a gate's typed check
/// (then kept prefixes give way, the capture is withdrawn, and the stop latch
/// or slot and the abort follow), or a check outside it, which would end the
/// worker on a real Mac too.
///
/// The switch is `cluster-setup/memory-fault` in the install that holds this
/// worker (`ClusterPlacementTool.installDirectory`), one integer N ≥ 1. The
/// worker reads it when a request starts and deletes it (one-shot); from
/// that request's Nth gate pass on, the reading is taken, and the request's
/// end disarms it. Only a worker in a dev or DevNet install
/// (`~/.darkbloom-dev`) reads it: in a production install it is never read.
public final class ClusterMemoryFault: @unchecked Sendable {
    public static let shared = ClusterMemoryFault()
    /// Tests: a fault of their own for the gates this task calls.
    @TaskLocal static var override: ClusterMemoryFault?
    static var current: ClusterMemoryFault { override ?? shared }

    static let switchPath = "cluster-setup/memory-fault"
    static let devInstallDirectoryName = ".darkbloom-dev"

    private let lock = NSLock()
    private var armed: (request: UUID, threshold: Int, passes: Int)?

    init() {}

    /// Whether a worker in `installDirectory` may read the switch: a dev or DevNet install's.
    static func permitted(installDirectory: URL) -> Bool {
        installDirectory.standardizedFileURL.lastPathComponent == devInstallDirectoryName
    }

    /// At a request's start: consumes the switch, if this is a dev install
    /// and it holds one, and arms it for `requestID` (in place of any earlier
    /// one; a fault armed for a request still running stays until its end
    /// otherwise). Returns N, or nil when nothing was armed.
    @discardableResult
    public func arm(requestID: UUID, installDirectory: URL = ClusterPlacementTool.installDirectory()) -> Int? {
        guard Self.permitted(installDirectory: installDirectory) else { return nil }
        let file = installDirectory.appendingPathComponent(Self.switchPath)
        guard let data = try? Data(contentsOf: file) else { return nil }
        // One-shot: the switch is gone before anything is armed, or nothing is.
        guard (try? FileManager.default.removeItem(at: file)) != nil else { return nil }
        guard data.count <= 32, let text = String(data: data, encoding: .utf8),
              let threshold = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...1_000_000).contains(threshold) else {
            log("darkbloom-memory-fault-v1 switch=malformed armed=false")
            return nil
        }
        lock.withLock { armed = (requestID, threshold, 0) }
        log("darkbloom-memory-fault-v1 request=\(requestID.uuidString.lowercased()) armed_check=\(threshold)")
        return threshold
    }

    /// At a request's end: its fault, if armed, ends with it.
    public func disarm(requestID: UUID) {
        lock.withLock { if armed?.request == requestID { armed = nil } }
    }

    /// The sample one pass of the host memory gate judges: `os` itself, or,
    /// from the armed request's Nth pass on, `os` with this Mac's memory taken.
    func reading(_ os: QwenDenseStageLoadOSObservation) -> QwenDenseStageLoadOSObservation {
        let due: (request: UUID, first: Bool)? = lock.withLock {
            guard var value = armed else { return nil }
            value.passes += 1; armed = value
            return value.passes >= value.threshold ? (value.request, value.passes == value.threshold) : nil
        }
        guard let due else { return os }
        if due.first {
            log("darkbloom-memory-fault-v1 request=\(due.request.uuidString.lowercased()) memory=taken")
        }
        return os.withMemoryTaken
    }
}

extension QwenDenseStageLoadOSObservation {
    /// This sample as the Mac would read it once another process had taken
    /// its free pages and its file cache: no free page (under the kernel's
    /// floor, `minimumTrulyFreeBytes`), no file cache, and every one of
    /// those pages anonymous memory in use. The counters stay consistent, so
    /// the policy judges it, and every requirement is refused.
    var withMemoryTaken: Self {
        let ceiling = physicalMemoryBytes / max(1, pageSizeBytes)
        return .init(startedNanoseconds: startedNanoseconds, completedNanoseconds: completedNanoseconds,
            timestampUTC: timestampUTC, physicalMemoryBytes: physicalMemoryBytes, pageSizeBytes: pageSizeBytes,
            kernelFreePages: 0, freePages: 0, inactivePages: inactivePages, speculativePages: 0,
            actualFreeBytes: 0, estimatedReclaimableBytes: inactivePages * pageSizeBytes,
            pressureLevel: pressureLevel, swapUsedBytes: swapUsedBytes,
            activePages: min(ceiling, activePages + kernelFreePages), fileBackedPages: 0,
            anonymousPages: min(ceiling, anonymousPages + kernelFreePages + fileBackedPages),
            wiredPages: wiredPages, purgeablePages: purgeablePages, compressorPages: compressorPages,
            kernelFileCacheMinimumPages: kernelFileCacheMinimumPages,
            inactiveFileBackedPages: inactiveFileBackedPages.map { _ in 0 },
            inactiveAnonymousPages: inactiveAnonymousPages.map { $0 + (inactiveFileBackedPages ?? 0) },
            compressionPages: compressionPages, swapoutPages: swapoutPages, liveCompressionPages: liveCompressionPages)
    }
}
