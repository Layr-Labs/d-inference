import Foundation

/// Dev and DevNet builds only: a one-shot fault that makes this rank's live
/// memory check refuse the next request, for proving on real Macs that a
/// refusal ends that request alone (D6). It refuses inside each live gate,
/// where the gate's own refusal is thrown, so everything after it (kept
/// prefixes giving way, the capture's withdrawal, the stop latch or slot, the
/// abort) is a real refusal's path.
///
/// The switch is `cluster-setup/memory-fault` in the install that holds this
/// worker (`ClusterPlacementTool.installDirectory`), one integer N ≥ 1. The
/// worker reads it when a request starts and deletes it (one-shot); from
/// that request's Nth live memory check on, the gate refuses, and the
/// request's end disarms it. Only a worker of a dev or DevNet app
/// (`~/.darkbloom-dev`) reads it: in a production install it is never read.
public final class ClusterMemoryFault: @unchecked Sendable {
    public static let shared = ClusterMemoryFault()
    /// Tests: a fault of their own for the gates this task calls.
    @TaskLocal static var override: ClusterMemoryFault?
    static var current: ClusterMemoryFault { override ?? shared }

    static let switchPath = "cluster-setup/memory-fault"
    static let devInstallDirectoryName = ".darkbloom-dev"

    private let lock = NSLock()
    private var armed: (request: UUID, threshold: Int, checks: Int)?

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

    /// In a live gate, where its refusal is thrown: from the armed request's
    /// Nth check on, a refusal.
    func refuseIfDue() throws {
        let due: Int? = lock.withLock {
            guard var value = armed else { return nil }
            value.checks += 1; armed = value
            return value.checks >= value.threshold ? value.checks : nil
        }
        if let due {
            throw ProbeError("the dev memory fault refused this rank's live memory check \(due) of the request")
        }
    }
}

/// The live memory gate the tensor-parallel families take for `bytes` more.
/// Power and thermal refusals stay untyped (they fail the worker); a memory
/// refusal is typed, so a running request's stop ends that request alone.
enum ClusterLiveMemory {
    static func requireTensorParallel(bytes: Int, family: String) throws {
        try QwenResidentResourceEnvironment.require()
        let watch = QwenDenseStageLoadWatch("\(family) tensor-parallel")
        let os = try QwenDenseStageLoadResources.observeOS()
        let free = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
            try QwenLongPrefillCheckedBytes.sum([bytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        do {
            try ClusterMemoryFault.current.refuseIfDue()
            guard try watch.admits(os, bytes: free) else {
                throw ProbeError("\(family) tensor parallel needs \(bytes) bytes the memory gate does not admit now")
            }
        } catch {
            throw QwenResidentMemoryRefusal(message: String(describing: error))
        }
    }
}
