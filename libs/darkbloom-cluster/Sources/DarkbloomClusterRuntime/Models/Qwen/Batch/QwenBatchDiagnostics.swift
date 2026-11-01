import Darwin
import Foundation

/// Counts only scheduling geometry. No request identity, tokens or payloads
/// enter the one-per-batch diagnostic line.
struct QwenBatchStepSummary {
    private(set) var steps = 0
    private(set) var decodeWidths = [Int](repeating: 0, count: 9)
    private(set) var pendingCreditObservations = 0
    private(set) var answeredCredits = 0
    private(set) var maximumPendingCredits = 0
    private(set) var prefillSteps = 0
    private(set) var joiningLanes = 0
    private(set) var leavingLanes = 0

    mutating func record(width: Int, pending: Int, answered: Int, prefill: Bool, joining: Int, leaving: Int) {
        precondition((0...8).contains(width) && (0...8).contains(pending) && (0...8).contains(answered))
        steps += 1; decodeWidths[width] += 1
        pendingCreditObservations += pending; answeredCredits += answered
        maximumPendingCredits = max(maximumPendingCredits, pending)
        prefillSteps += prefill ? 1 : 0; joiningLanes += joining; leavingLanes += leaving
    }

    var line: String {
        "darkbloom-batch-geometry-v1 rank=0 steps=\(steps) decode_width_counts=\(decodeWidths.map(String.init).joined(separator: ","))"
            + " pending_credit_observations=\(pendingCreditObservations) answered_credits=\(answeredCredits)"
            + " max_pending_credits=\(maximumPendingCredits) prefill_steps=\(prefillSteps)"
            + " joined_lanes=\(joiningLanes) left_lanes=\(leavingLanes)"
    }
}

/// Explicit private qualification output, separate from telemetry and normal
/// evidence. Copies native logical bytes without converting or selecting rows.
/// One process holds the directory lock; the cap includes previous batches.
final class QwenBatchRowCapture {
    static let environmentName = "DARKBLOOM_CLUSTER_BATCH_LOGIT_DIRECTORY"
    static let traceEnvironmentName = "DARKBLOOM_CLUSTER_BATCH_TRACE"
    static let ordinals: Set<Int> = [0, 1, 30, 37, 78, 88]
    static let maximumCaptures = 256
    static let maximumRowBytes = 1_048_576
    private let directory: Int32
    private var count: Int

    struct Context {
        let batchOrdinal: UInt64
        let step: Int
        let slot: Int
        let row: Int
        let decodeWidth: Int
        let phase: String
        let requestID: UUID
        let requestFingerprint: String
        let promptTokens: [Int]
        let priorSelectedTokens: [Int]
        let selectedToken: Int
    }

    struct Record: Codable {
        let schema: String
        let rank: Int
        let batchOrdinal: UInt64
        let step: Int
        let slot: Int
        let row: Int
        let decodeWidth: Int
        let phase: String
        let requestID: UUID
        let requestFingerprint: String
        let outputOrdinal: Int
        let selectedToken: Int
        let promptTokenCount: Int
        let promptTokensSHA256: String
        let priorHistorySHA256: String
        let shape: [Int]
        let dtype: String
        let byteCount: Int
        let logicalBytesSHA256: String
        let bytesFile: String
    }

    static func traceRequested(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Bool {
        guard let value = environment[traceEnvironmentName] else { return false }
        guard value == "1" else { throw ProbeError("Batch trace takes only 1") }
        return true
    }

    static func fromEnvironment(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> QwenBatchRowCapture? {
        guard let path = environment[environmentName] else { return nil }
        return try .init(path: path)
    }

    init(path: String) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 768, path != "/",
              !path.utf8.contains(0), !path.contains("\n") else { throw ProbeError("Batch logits need an absolute bounded private directory") }
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProbeError("Batch logit directory could not be opened without following a link") }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd); throw ProbeError("Batch logit directory must be private, owned by this user and unused")
        }
        guard let stream = fdopendir(dup(fd)) else {
            Darwin.close(fd); throw ProbeError("Batch logit directory could not be inventoried")
        }
        var existing = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            if name.hasSuffix(".bin") { existing += 1 }
        }
        closedir(stream)
        guard existing < Self.maximumCaptures else {
            Darwin.close(fd); throw ProbeError("Batch logit capture limit reached")
        }
        directory = fd; count = existing
    }

    deinit { Darwin.close(directory) }

    func capture(_ context: Context, shape: [Int], dtype: String, bytes: () throws -> Data) throws {
        let ordinal = context.priorSelectedTokens.count
        guard Self.ordinals.contains(ordinal) else { return }
        let elementBytes: Int
        switch dtype {
        case "float16", "bfloat16": elementBytes = 2
        case "float32": elementBytes = 4
        default: throw ProbeError("Batch logit capture requires native floating rows")
        }
        guard count < Self.maximumCaptures, shape.count == 2, shape[0] == 1,
              (1...262_144).contains(shape[1]), context.batchOrdinal > 0, context.step >= 0,
              (0..<8).contains(context.slot), (0..<8).contains(context.row),
              (1...8).contains(context.decodeWidth), context.row < context.decodeWidth,
              ["prefill", "decode"].contains(context.phase), !context.promptTokens.isEmpty,
              context.requestFingerprint.count == 64, (0..<shape[1]).contains(context.selectedToken) else {
            throw ProbeError("Batch logit capture exceeds its geometry or count bound")
        }
        let raw = try bytes()
        guard raw.count == shape[1] * elementBytes, raw.count <= Self.maximumRowBytes else {
            throw ProbeError("Batch logit capture native byte count differs")
        }
        let stem = "b\(context.batchOrdinal)-s\(context.step)-l\(context.slot)-o\(ordinal)-\(context.requestID.uuidString.lowercased())"
        let record = Record(schema: "qwen-batch-native-row-v1", rank: 1, batchOrdinal: context.batchOrdinal,
            step: context.step, slot: context.slot, row: context.row, decodeWidth: context.decodeWidth,
            phase: context.phase, requestID: context.requestID, requestFingerprint: context.requestFingerprint,
            outputOrdinal: ordinal, selectedToken: context.selectedToken, promptTokenCount: context.promptTokens.count,
            promptTokensSHA256: QwenLayerStageBoundary.tokenHash(context.promptTokens),
            priorHistorySHA256: QwenLayerStageBoundary.tokenHash(context.promptTokens + context.priorSelectedTokens),
            shape: shape, dtype: dtype, byteCount: raw.count, logicalBytesSHA256: sha256(raw), bytesFile: stem + ".bin")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(record)
        guard encoded.count <= 4096 else { throw ProbeError("Batch logit metadata exceeds its bound") }
        try writeNew(raw, name: stem + ".bin")
        count += 1 // A partial metadata write still consumes its byte budget.
        try writeNew(encoded, name: stem + ".json")
    }

    private func writeNew(_ data: Data, name: String) throws {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProbeError("Batch logit file already exists or cannot be created") }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw ProbeError("Batch logit file write failed") }
                offset += written
            }
        }
    }
}
