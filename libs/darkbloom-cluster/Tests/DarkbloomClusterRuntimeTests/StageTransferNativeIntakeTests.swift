import CryptoKit
import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

// The MLX side of a stage transfer on a small real safetensors file: a sender
// core over the verified checkpoint, a receiver core into the native intake,
// both in this process on one thread. No model, no collective. The load's
// gate is a recording stand-in: the real one needs a prepared stage.

/// Records what a payload source asks the load's gate, and can refuse one
/// tensor before it is stored or one observation after a tensor has settled.
private final class RecordingGate: QwenLayerStageGate {
    private(set) var asked: [String] = []
    private(set) var observed = 0
    var refused: String?
    var refusedObservation: Int?

    func beforeRead(_ entry: QwenStageActiveTensor) throws {
        asked.append(entry.sourceName)
        if entry.sourceName == refused { throw ProbeError("Recording gate refused \(entry.sourceName)") }
    }

    func observe() throws {
        observed += 1
        if observed == refusedObservation { throw ProbeError("Recording gate refused observation \(observed)") }
    }
}

private struct TransferFileFixture {
    static let file = "model-00001-of-00001.safetensors"
    let root: URL
    let config = Data(#"{"arch":"transfer-fixture"}"#.utf8)
    /// (name, dtype, shape, bytes) in payload order. `a` and `b` differ only in content.
    let tensors: [(name: String, dtype: String, shape: [Int], bytes: Data)]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transfer-fixture-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func pattern(_ count: Int, _ seed: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ seed &* 101) }) }
        tensors = [
            ("model.b.weight", "U32", [4, 4], pattern(64, 1)), ("model.embed.weight", "U32", [10, 4], pattern(160, 2)),
            ("model.a.weight", "U32", [4, 4], pattern(64, 3)), ("model.a.scales", "BF16", [4, 2], pattern(16, 4)),
        ]
        var header: [String: Any] = [:], payload = Data()
        for tensor in tensors {
            header[tensor.name] = ["dtype": tensor.dtype, "shape": tensor.shape,
                                   "data_offsets": [payload.count, payload.count + tensor.bytes.count]]
            payload.append(tensor.bytes)
        }
        let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        var length = UInt64(headerData.count).littleEndian
        let stored = Data(bytes: &length, count: 8) + headerData + payload
        try stored.write(to: root.appendingPathComponent(Self.file))
        try config.write(to: root.appendingPathComponent("config.json"))
        func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        var aggregate = SHA256()
        aggregate.update(data: Data(SHA256.hash(data: config))); aggregate.update(data: Data(SHA256.hash(data: stored)))
        try JSONSerialization.data(withJSONObject: [
            "aggregate_sha256": aggregate.finalize().map { String(format: "%02x", $0) }.joined(),
            "file_count": 2, "total_size_bytes": config.count + stored.count,
            "files": [["path": "config.json", "sha256": hex(config), "size_bytes": config.count],
                      ["path": Self.file, "sha256": hex(stored), "size_bytes": stored.count]],
        ] as [String: Any], options: [.sortedKeys]).write(to: root.appendingPathComponent("manifest.json"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// A verified checkpoint, a session over one delivered stage and that stage's active inventory.
    func session() throws -> (checkpoint: VerifiedCheckpoint, session: QwenStageTransferSession,
                              active: [QwenStageActiveTensor]) {
        let checkpoint = try VerifiedCheckpoint(directory: root, configurationData: config)
        let inventory = try layerStageTensorContentInventory(tensorDescriptors(checkpoint: checkpoint), check: {})
        let active = tensors.sorted { $0.name < $1.name }.map { tensor in
            let native = QwenStageStoredDType(rawValue: tensor.dtype)!.nativeName
            return QwenStageActiveTensor(sourceName: tensor.name, localName: tensor.name, shape: tensor.shape,
                                         sourceDType: native, loadedDType: native, byteCount: tensor.bytes.count)
        }
        // Pieces of at most three 16-byte rows: the ten-row tensor arrives as four pieces.
        let plan = try QwenStageTransferPlan(stages: [.init(stageIndex: 1, active: active)],
            limits: .init(pieceByteLimit: 48, windowByteLimit: 96, windowPieceLimit: 3))
        return (checkpoint, try QwenStageTransferSession(loadAgreementFingerprint: String(repeating: "e", count: 64),
                                                        plan: plan, inventory: inventory), active)
    }

    static func watch() -> QwenStageTransferWatch {
        QwenStageTransferWatch(deadlines: .init(lifetimeUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 300_000_000_000,
            startupUptimeNanoseconds: nil, progressTimeoutNanoseconds: 60_000_000_000),
            now: { DispatchTime.now().uptimeNanoseconds }, check: { _ in })
    }
}

@Suite("Stage transfer native intake (CPU fixtures, one process)")
struct StageTransferNativeIntakeTests {
    @Test func everyTensorArrivesByteIdenticalInItsOwnShapeAndDType() throws {
        let fixture = try TransferFileFixture()
        defer { fixture.remove() }
        let (checkpoint, session, active) = try fixture.session()
        #expect(session.plan.tensors.map(\.pieces.count) == [1, 2, 2, 4])
        let gate = RecordingGate()
        let intake = try runQwenStageTransferInProcess(session: session,
            source: QwenStageCheckpointByteSource(checkpoint: checkpoint), active: active, gate: gate, hashThreads: 3,
            watch: TransferFileFixture.watch, check: {})
        #expect(intake.heldTensorCount == 4)
        // The gate was asked before each tensor took its storage, in inventory order, and once after each.
        #expect(gate.asked == active.map(\.sourceName) && gate.observed == 4)
        for (index, tensor) in session.plan.tensors.enumerated() {
            let stored = try #require(fixture.tensors.first { $0.name == tensor.sourceName })
            let array = try #require(intake.take(index))
            #expect(array.shape == stored.shape && array.dtype == tensor.dtype.native)
            #expect(array.asData(access: .copy).data == stored.bytes)
        }
        #expect(intake.heldTensorCount == 0 && intake.take(0) == nil)
    }

    @Test func aWrongSenderIsRefusedForItsOwnReason() throws {
        let fixture = try TransferFileFixture()
        defer { fixture.remove() }
        let (checkpoint, session, active) = try fixture.session()
        let source = QwenStageCheckpointByteSource(checkpoint: checkpoint)
        let a = session.records[1].source, b = session.records[2].source
        #expect(session.plan.tensors[1].sourceName == "model.a.weight" && session.plan.tensors[2].sourceName == "model.b.weight")
        let faults: [(QwenStageFaultyByteSource.Fault, String)] = [
            (.flippedBit(piece: 0), "Stage tensor content differs from its pinned SHA-256: model.a.scales"),
            (.truncated(piece: 5), "Stage transfer piece differs from its planned shape, dtype or size"),
            // Two tensors of one shape and dtype, each sent the other's stored bytes.
            (.substituted(["\(a.sourceFile)|\(a.sourceOffset)": (b.sourceFile, b.sourceOffset),
                           "\(a.sourceFile)|\(a.sourceOffset + 32)": (b.sourceFile, b.sourceOffset + 32),
                           "\(b.sourceFile)|\(b.sourceOffset)": (a.sourceFile, a.sourceOffset),
                           "\(b.sourceFile)|\(b.sourceOffset + 32)": (a.sourceFile, a.sourceOffset + 32)]),
             "Stage tensor content differs from its pinned SHA-256: model.a.weight"),
        ]
        // One hashing thread reports digests in arrival order, so the first refusal is the same every run.
        for (fault, reason) in faults {
            let refusal = #expect(throws: ProbeError.self) {
                _ = try runQwenStageTransferInProcess(session: session,
                    source: QwenStageFaultyByteSource(source: source, fault: fault), active: active,
                    gate: RecordingGate(), hashThreads: 1, watch: TransferFileFixture.watch, check: {})
            }
            #expect(refusal?.description == reason)
        }
    }

    @Test func aTensorTheGateRefusesEndsTheTransferBeforeItIsStored() throws {
        let fixture = try TransferFileFixture()
        defer { fixture.remove() }
        let (checkpoint, session, active) = try fixture.session()
        let gate = RecordingGate()
        gate.refused = "model.b.weight"
        let refusal = #expect(throws: ProbeError.self) {
            _ = try runQwenStageTransferInProcess(session: session,
                source: QwenStageCheckpointByteSource(checkpoint: checkpoint), active: active, gate: gate,
                hashThreads: 1, watch: TransferFileFixture.watch, check: {})
        }
        #expect(refusal?.description == "Recording gate refused model.b.weight")
        // Asked up to the refused tensor and no further; only the two before it settled.
        #expect(gate.asked == ["model.a.scales", "model.a.weight", "model.b.weight"] && gate.observed == 2)

        // The gate can also refuse once a tensor has settled; nothing after it is asked about.
        let settled = RecordingGate()
        settled.refusedObservation = 2
        let later = #expect(throws: ProbeError.self) {
            _ = try runQwenStageTransferInProcess(session: session,
                source: QwenStageCheckpointByteSource(checkpoint: checkpoint), active: active, gate: settled,
                hashThreads: 1, watch: TransferFileFixture.watch, check: {})
        }
        #expect(later?.description == "Recording gate refused observation 2")
        #expect(settled.asked == ["model.a.scales", "model.a.weight"] && settled.observed == 2)
    }

    @Test func theTransferredPayloadHandsEachVerifiedTensorOverOnce() throws {
        let fixture = try TransferFileFixture()
        defer { fixture.remove() }
        let (checkpoint, session, active) = try fixture.session()
        var planned: [String] = []
        let payload = QwenStageTransferredPayload { delivered, gate in
            planned = delivered.map(\.sourceName)
            return try runQwenStageTransferInProcess(session: session,
                source: QwenStageCheckpointByteSource(checkpoint: checkpoint), active: delivered, gate: gate,
                watch: TransferFileFixture.watch, check: {})
        }
        let gate = RecordingGate()
        var askedAgain = 0
        #expect(throws: ProbeError.self) { _ = try payload.tensor(active[0], beforeRead: { _ in askedAgain += 1 }) }
        try payload.begin(active, gate: gate)
        #expect(planned == active.map(\.sourceName) && gate.asked == planned)
        #expect(throws: ProbeError.self) { try payload.finish() }
        for entry in active {
            let tensor = try payload.tensor(entry, beforeRead: { _ in askedAgain += 1 })
            #expect(tensor.array.shape == entry.shape && tensor.copiedBytes == entry.byteCount)
            #expect(tensor.largestHostTensorBytes == entry.byteCount && tensor.readAccounting == nil)
        }
        #expect(throws: ProbeError.self) { _ = try payload.tensor(active[0], beforeRead: { _ in askedAgain += 1 }) }
        // Each tensor passed the gate as it arrived; taking it does not ask a second time.
        #expect(askedAgain == 0 && gate.asked.count == active.count)
        try payload.finish()
    }

    @Test func theIntakeRefusesAPieceThatIsNotThePlannedOneAndReleasesOnDiscard() throws {
        let fixture = try TransferFileFixture()
        defer { fixture.remove() }
        let (_, session, active) = try fixture.session()
        let plan = session.plan, gate = RecordingGate()
        // An inventory that is not the plan's has no place here: the gate is asked by its entries.
        let mismatched = #expect(throws: ProbeError.self) {
            _ = try QwenStageNativeIntake(plan: plan, active: Array(active.reversed()), gate: gate, check: {})
        }
        #expect(mismatched?.description == "Stage transfer intake needs the active inventory its plan was made from")
        // A tensor the loader would convert after loading would be copied with no question to the gate.
        var converting = active
        converting[0] = QwenStageActiveTensor(sourceName: active[0].sourceName, localName: active[0].localName,
            shape: active[0].shape, sourceDType: active[0].sourceDType, loadedDType: "float32", byteCount: active[0].byteCount)
        let converted = #expect(throws: ProbeError.self) {
            _ = try QwenStageNativeIntake(plan: plan, active: converting, gate: gate, check: {})
        }
        #expect(converted?.description == "Stage transfer intake takes no tensor the loader would convert")
        // A fault outside the intake is reported as itself, not as a wrong piece.
        let faulted = try QwenStageNativeIntake(plan: plan, active: active, gate: RecordingGate(),
                                                check: { throw ProbeError("native fault") })
        let fault = #expect(throws: ProbeError.self) {
            try faulted.accept(MLXArray.zeros([2, 4], dtype: .bfloat16), for: plan.pieces[0])
        }
        #expect(fault?.description == "native fault")
        let intake = try QwenStageNativeIntake(plan: plan, active: active, gate: gate, hashThreads: 1, check: {})
        // Piece 0 is the whole BF16 [4, 2] tensor.
        for wrong in [MLXArray.zeros([4, 2], dtype: .float16), MLXArray.zeros([2, 4], dtype: .bfloat16), MLXArray.zeros([4, 4], dtype: .bfloat16)] {
            let refusal = #expect(throws: ProbeError.self) { try intake.accept(wrong, for: plan.pieces[0]) }
            #expect(refusal?.description == "Stage transfer piece differs from its planned shape, dtype or size")
        }
        #expect(gate.asked.isEmpty)
        try intake.accept(MLXArray.zeros([4, 2], dtype: .bfloat16), for: plan.pieces[0])
        #expect(intake.heldTensorCount == 1 && gate.asked == ["model.a.scales"] && gate.observed == 1)
        // A split tensor is asked about when its first piece arrives and observed when its last one has.
        #expect(plan.tensors[1].pieces == 1 ..< 3 && plan.tensors[2].pieces == 3 ..< 5)
        try intake.accept(MLXArray.zeros(plan.pieces[1].shape, dtype: .uint32), for: plan.pieces[1])
        #expect(gate.asked == ["model.a.scales", "model.a.weight"] && gate.observed == 1 && intake.heldTensorCount == 1)
        try intake.accept(MLXArray.zeros(plan.pieces[2].shape, dtype: .uint32), for: plan.pieces[2])
        #expect(gate.asked.count == 2 && gate.observed == 2 && intake.heldTensorCount == 2)
        // A tensor the gate refuses is not stored.
        gate.refused = "model.b.weight"
        let unadmitted = #expect(throws: ProbeError.self) {
            try intake.accept(MLXArray.zeros(plan.pieces[3].shape, dtype: .uint32), for: plan.pieces[3])
        }
        #expect(unadmitted?.description == "Recording gate refused model.b.weight" && intake.heldTensorCount == 2)
        #expect(try intake.completedDigests(joining: true).map(\.contentSHA256) == [sha256(Data(count: 16)), sha256(Data(count: 64))])
        intake.discard()
        #expect(intake.heldTensorCount == 0 && intake.take(0) == nil)
    }

    @Test func theSenderSourceReadsOnlyFilesOfItsVerifiedCheckpoint() throws {
        let fixture = try TransferFileFixture()
        defer { fixture.remove() }
        let (checkpoint, session, _) = try fixture.session()
        let source = QwenStageCheckpointByteSource(checkpoint: checkpoint)
        let location = session.records[0].source
        #expect(try source.bytes(session.plan.pieces[0], file: location.sourceFile, offset: location.sourceOffset)
            == fixture.tensors.first { $0.name == "model.a.scales" }?.bytes)
        let refusal = #expect(throws: ProbeError.self) {
            _ = try source.read(session.plan.pieces[0], file: "another.safetensors", offset: location.sourceOffset)
        }
        #expect(refusal?.description == "Stage transfer source file is not in the verified checkpoint")
    }

    /// The loader seam's local payload: the same verified read the loader always made.
    @Test func theLocalPayloadSuppliesExactBytesWithReadAccountingOnceBegun() throws {
        let fixture = try TransferFileFixture()
        defer { fixture.remove() }
        let checkpoint = try VerifiedCheckpoint(directory: fixture.root, configurationData: fixture.config)
        let payload = QwenVerifiedCheckpointPayload(checkpoint: checkpoint,
            canonical: try composeQwenCheckpointTensors(tensorDescriptors(checkpoint: checkpoint)))
        func entry(_ name: String, _ shape: [Int], _ bytes: Int) -> QwenStageActiveTensor {
            .init(sourceName: name, localName: name, shape: shape, sourceDType: "uint32", loadedDType: "uint32", byteCount: bytes)
        }
        let embed = entry("model.embed.weight", [10, 4], 160)
        let gate = RecordingGate()
        var asked: [String] = []
        // Before `begin` the descriptor reads through the file cache, with no aligned-read accounting.
        let early = #expect(throws: ProbeError.self) { _ = try payload.tensor(embed, beforeRead: { asked.append($0.sourceName) }) }
        #expect(early?.description == "Selected-stage aligned read accounting is incomplete")
        try payload.begin([embed], gate: gate)
        let read = try payload.tensor(embed, beforeRead: { asked.append($0.sourceName) })
        #expect(read.array.shape == [10, 4] && read.array.dtype == .uint32)
        #expect(read.array.asData(access: .copy).data == fixture.tensors.first { $0.name == "model.embed.weight" }?.bytes)
        #expect(read.copiedBytes == 160 && read.largestHostTensorBytes == 160 && read.readAccounting?.selectedBytes == 160)
        let unknown = #expect(throws: ProbeError.self) {
            _ = try payload.tensor(entry("model.missing.weight", [1], 4), beforeRead: { asked.append($0.sourceName) })
        }
        #expect(unknown?.description == "Verified stage descriptor disappeared")
        // Asked once for each tensor it had, before the read, and never for one it did not have.
        // The local source reads when it is asked, so it leaves the gate object itself alone.
        #expect(asked == ["model.embed.weight", "model.embed.weight"] && gate.asked.isEmpty && gate.observed == 0)
        try payload.finish()
    }
}
