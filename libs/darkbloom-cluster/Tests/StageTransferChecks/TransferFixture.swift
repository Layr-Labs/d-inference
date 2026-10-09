import Foundation

/// Two real safetensors files in a temporary directory, split into two stages.
/// Stage 0 holds two tensors of one shape, so a transfer that swaps them is
/// distinguishable only by content. Stage 1 holds one tensor of ten rows, which
/// the small piece limit below cuts into four pieces.
struct TinyStageArtifact {
    struct Stored {
        let name: String, localName: String
        let stage: Int
        let dtype: QwenStageStoredDType
        let shape: [Int]
        let file: String
        var byteCount: Int { shape.reduce(dtype.elementBytes, *) }
    }

    static let first = "model-00001-of-00002.safetensors", second = "model-00002-of-00002.safetensors"
    /// In payload order within each file, which is not name order.
    static let stored = [
        Stored(name: "language_model.model.layers.0.b.weight", localName: "language_model.model.layers.0.b.weight",
               stage: 0, dtype: .uint32, shape: [4, 4], file: first),
        Stored(name: "language_model.model.embed_tokens.weight", localName: "language_model.model.embed_tokens.weight",
               stage: 0, dtype: .uint32, shape: [8, 4], file: first),
        Stored(name: "language_model.model.layers.0.a.weight", localName: "language_model.model.layers.0.a.weight",
               stage: 0, dtype: .uint32, shape: [4, 4], file: first),
        Stored(name: "language_model.model.layers.0.a.scales", localName: "language_model.model.layers.0.a.scales",
               stage: 0, dtype: .bfloat16, shape: [4, 2], file: first),
        Stored(name: "language_model.lm_head.weight", localName: "language_model.lm_head.weight",
               stage: 1, dtype: .uint32, shape: [10, 4], file: second),
        Stored(name: "language_model.model.layers.1.A_log", localName: "language_model.model.layers.0.A_log",
               stage: 1, dtype: .float32, shape: [3], file: second),
        Stored(name: "language_model.model.layers.1.a.weight", localName: "language_model.model.layers.0.a.weight",
               stage: 1, dtype: .uint32, shape: [4, 4], file: second),
    ]
    /// Pieces of at most three 16-byte rows; windows of at most 96 bytes or three pieces.
    static let limits = try! QwenStageTransferLimits(pieceByteLimit: 48, windowByteLimit: 96, windowPieceLimit: 3)

    let directory: URL
    let inventory: LayerStageTensorContentInventory
    let content: [String: Data]
    let stages: [QwenStageTransferPlan.DeliveredStage]

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage-transfer-fixture-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var records: [LayerStageTensorContentRecord] = [], content: [String: Data] = [:]
        for file in [Self.first, Self.second] {
            // safetensors: 8-byte little-endian header length, JSON header, then payloads.
            var header: [String: Any] = ["__metadata__": ["format": "mlx"]], payload = Data()
            let tensors = Self.stored.filter { $0.file == file }
            for tensor in tensors {
                let seed = content.count
                let bytes = Data((0..<tensor.byteCount).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ seed &* 101 &+ 11) })
                header[tensor.name] = ["dtype": tensor.dtype.rawValue, "shape": tensor.shape,
                                       "data_offsets": [payload.count, payload.count + bytes.count]]
                content[tensor.name] = bytes; payload.append(bytes)
            }
            let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
            var length = UInt64(headerData.count).littleEndian
            try (Data(bytes: &length, count: 8) + headerData + payload)
                .write(to: directory.appendingPathComponent(file), options: .withoutOverwriting)
            var offset = 8 + headerData.count
            for tensor in tensors {
                let layout = try LayerStageTensorLayout(canonicalName: tensor.name, shape: tensor.shape,
                    sourceDType: tensor.dtype.rawValue, byteCount: tensor.byteCount)
                records.append(try .init(source: .init(layout: layout, sourceFile: file, sourceOffset: offset),
                                         contentSHA256: sha256(content[tensor.name]!)))
                offset += tensor.byteCount
            }
        }
        inventory = try LayerStageTensorContentInventory(records: records)
        self.content = content
        // `inventory.active` order: ascending local name within the stage.
        stages = (0...1).map { stage in
            .init(stageIndex: stage, active: Self.stored.filter { $0.stage == stage }
                .sorted { $0.localName < $1.localName }.map {
                    QwenStageActiveTensor(sourceName: $0.name, localName: $0.localName, shape: $0.shape,
                        sourceDType: $0.dtype.nativeName, loadedDType: $0.dtype.nativeName, byteCount: $0.byteCount)
                })
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func session(stages delivered: [Int] = [0, 1], epoch: Character = "e",
                 limits: QwenStageTransferLimits = limits) throws -> QwenStageTransferSession {
        try QwenStageTransferSession(loadAgreementFingerprint: String(repeating: epoch, count: 64),
            plan: QwenStageTransferPlan(stages: delivered.map { stages[$0] }, limits: limits), inventory: inventory)
    }
}

/// What a state machine asked of its byte source or intake, by piece index.
final class TransferCallLog {
    var read: [Int] = [], placeholders: [Int] = [], accepted: [Int] = []
    var digestCollections = 0
}

/// Reads the artifact's files, with the faults a wrong or failing sender has.
struct FileByteSource: QwenStageTransferByteSource {
    let directory: URL
    let log = TransferCallLog()
    /// Flips the lowest bit of the first byte of this piece.
    var flippedPiece: Int?
    var failingPiece: Int?
    /// Serves another offset of the same file in place of the pinned one.
    var substitutedOffsets: [Int: Int] = [:]

    func read(_ piece: QwenStageTransferPlan.Piece, file: String, offset: Int) throws -> Data {
        log.read.append(piece.index)
        if piece.index == failingPiece { throw ProbeError("injected read failure") }
        let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(file))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(substitutedOffsets[offset] ?? offset))
        var data = try handle.read(upToCount: piece.byteCount) ?? Data()
        guard data.count == piece.byteCount else { throw ProbeError("fixture read was short") }
        if piece.index == flippedPiece { data[data.startIndex] ^= 1 }
        return data
    }

    func placeholder(_ piece: QwenStageTransferPlan.Piece) throws -> Data {
        log.placeholders.append(piece.index)
        return Data(count: piece.byteCount)
    }
}

/// Keeps host bytes per tensor and hashes a tensor when its last piece arrives.
struct MemoryIntake: QwenStageTransferIntake {
    let plan: QwenStageTransferPlan
    let log = TransferCallLog()
    /// Report digests only when joined, as while hash jobs are still running.
    var deferred = false
    var failingPiece: Int?
    var withheldTensor: Int?
    var reportsUnknownTensor = false
    private(set) var assembled: [Int: Data] = [:]
    private var pending: [(tensor: Int, contentSHA256: String)] = []

    init(plan: QwenStageTransferPlan) { self.plan = plan }

    mutating func accept(_ payload: Data, for piece: QwenStageTransferPlan.Piece) throws {
        log.accepted.append(piece.index)
        if piece.index == failingPiece { throw ProbeError("injected intake failure") }
        assembled[piece.tensor, default: Data()].append(payload)
        if piece.index + 1 == plan.tensors[piece.tensor].pieces.upperBound, piece.tensor != withheldTensor {
            pending.append((piece.tensor, sha256(assembled[piece.tensor]!)))
        }
    }

    mutating func completedDigests(joining: Bool) throws -> [(tensor: Int, contentSHA256: String)] {
        log.digestCollections += 1
        guard joining || !deferred else { return [] }
        defer { pending = [] }
        return pending + (reportsUnknownTensor ? [(plan.tensors.count, String(repeating: "0", count: 64))] : [])
    }
}

/// A rank's uptime clock and the resident control's check, both under test control.
final class TransferTestClock {
    var now: UInt64
    var cancelled = false
    init(_ now: UInt64) { self.now = now }

    func watch(lifetime: UInt64? = nil, startup: UInt64? = nil,
               progressTimeout: UInt64 = 60_000_000_000) -> QwenStageTransferWatch {
        let lifetime = lifetime ?? now + 300_000_000_000
        return QwenStageTransferWatch(deadlines: .init(lifetimeUptimeNanoseconds: lifetime,
            startupUptimeNanoseconds: startup, progressTimeoutNanoseconds: progressTimeout),
            now: { self.now }, check: { deadline in
                // The contract of `QwenResidentControl.check(deadline:)`.
                guard !self.cancelled, self.now < lifetime, deadline.map({ self.now < $0 }) ?? true else {
                    throw ProbeError("Resident operation cancelled or past its absolute local deadline")
                }
            })
    }
}
