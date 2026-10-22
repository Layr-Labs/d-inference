import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXNN

/// How a tensor-parallel GLM rank reads its weights. The product reads them
/// `prepared`; the others exist to compare (`DARKBLOOM_CLUSTER_LOAD_PATH`,
/// diagnosis only). Every path builds the same arrays, byte for byte
/// (`GLM5NextTensorParallelLoadDigest` shows it on the real model).
enum GLM5NextTensorParallelLoadPath: String, CaseIterable {
    /// One read of every file that checks its SHA-256 and copies the rank's
    /// bytes straight into their final buffers (`GLM5NextArtifactLoader
    /// .prepare`), through the file cache, so the files stay cached for the
    /// next load. Measured on an M5 Ultra: 14 GB/s from the SSD, 101 GB/s
    /// from the cache.
    case prepared
    /// The same pass, bypassing the file cache (cached pages are still used).
    case preparedUncached = "prepared-uncached"
    /// The per-tensor loader: every file hashed first, then each tensor read
    /// whole, copied into MLX, sliced and stacked (72-75 s per rank,
    /// 2026-10-21).
    case perTensor = "per-tensor"

    static let environmentKey = "DARKBLOOM_CLUSTER_LOAD_PATH"

    static func resolved(_ environment: [String: String]) throws -> Self {
        guard let raw = environment[environmentKey] else { return .prepared }
        guard let value = Self(rawValue: raw) else {
            throw ProbeError("\(environmentKey) must be one of "
                + allCases.map(\.rawValue).joined(separator: ", "))
        }
        return value
    }

    var verification: GLM5NextArtifactVerification {
        self == .perTensor ? .beforeLoad : .withPreparedPayload
    }
}

/// Where one rank's load time goes, as one line beside
/// `darkbloom-tensor-parallel-load-v1`: when the load began on the wall clock
/// (to line it up with the provider's timestamped log), then each phase's
/// nanoseconds, in order.
struct GLM5NextTensorParallelLoadPhases {
    private var phases: [(String, UInt64)] = []
    private var last: UInt64
    private let startedUnixMilliseconds: Int64

    init(since start: UInt64, startedUnixMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        last = start
        self.startedUnixMilliseconds = startedUnixMilliseconds
    }

    /// Closes the phase that ran since the previous mark.
    mutating func mark(_ name: String, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        phases.append((name, now >= last ? now - last : 0))
        last = now
    }

    func line(rank: Int, path: GLM5NextTensorParallelLoadPath) -> String {
        "darkbloom-tensor-parallel-load-phases-v1 rank=\(rank) path=\(path.rawValue)"
            + " started_unix_ms=\(startedUnixMilliseconds) "
            + phases.map { "\($0.0)_ns=\($0.1)" }.joined(separator: " ")
    }
}

/// The SHA-256 of every array a loaded rank holds, for comparing load paths
/// and builds on the real model (`DARKBLOOM_CLUSTER_LOAD_DIGESTS`, diagnosis
/// only: `1` logs one aggregate line, `tensors` also a line per array). The
/// aggregate is the SHA-256 of the sorted `key shape dtype sha256` lines, so
/// two loads that hold the same bytes under the same names agree.
enum GLM5NextTensorParallelLoadDigest {
    static let environmentKey = "DARKBLOOM_CLUSTER_LOAD_DIGESTS"

    struct Entry: Equatable {
        let key: String
        let shape: [Int]
        let dtype: String
        let sha256: String
        var line: String { "\(key) \(shape.map(String.init).joined(separator: "x")) \(dtype) \(sha256)" }
    }

    /// Every parameter of `modules`, keyed `<module index>.<parameter path>`;
    /// hashed on all cores.
    static func entries(_ modules: [Module]) -> [Entry] {
        var named: [(String, MLXArray)] = []
        for (index, module) in modules.enumerated() {
            named += module.parameters().flattened().map { ("\(index).\($0.0)", $0.1) }
        }
        // The bytes are found on this thread (MLX), then only hashed in
        // parallel; the lock guards only the results.
        final class Work: @unchecked Sendable {
            let data: [Data]
            let lock = NSLock()
            var digests: [String]
            init(_ data: [Data]) { self.data = data; digests = Array(repeating: "", count: data.count) }
        }
        let work = Work(named.map { $0.1.asData(access: .noCopyIfContiguous).data })
        DispatchQueue.concurrentPerform(iterations: work.data.count) { index in
            let digest = SHA256.hash(data: work.data[index]).map { String(format: "%02x", $0) }.joined()
            work.lock.withLock { work.digests[index] = digest }
        }
        return named.indices.map {
            Entry(key: named[$0].0, shape: named[$0].1.shape, dtype: "\(named[$0].1.dtype)",
                  sha256: work.digests[$0])
        }
    }

    static func aggregate(_ entries: [Entry]) -> String {
        let text = entries.map(\.line).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The lines to log, or none when the switch is off.
    static func lines(_ modules: [Module], rank: Int, path: GLM5NextTensorParallelLoadPath,
                      environment: [String: String]) -> [String] {
        guard let mode = environment[environmentKey], mode == "1" || mode == "tensors" else { return [] }
        let all = entries(modules)
        let bytes = all.reduce(0) { $0 + ($1.shape.reduce(1, *)) }
        var lines = ["darkbloom-tensor-parallel-load-digest-v1 rank=\(rank) path=\(path.rawValue)"
            + " arrays=\(all.count) elements=\(bytes) digest=\(aggregate(all))"]
        if mode == "tensors" {
            lines += all.sorted { $0.key < $1.key }.map {
                "darkbloom-tensor-parallel-load-tensor-v1 rank=\(rank) \($0.line)"
            }
        }
        return lines
    }
}
