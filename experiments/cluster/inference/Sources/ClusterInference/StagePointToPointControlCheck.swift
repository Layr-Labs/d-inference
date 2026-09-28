import Foundation
import MLX

struct StagePointToPointControlRecord: Encodable, Equatable {
    let caseID: String
    let dtype: String
    let shape: [Int]
    let byteCount: Int
    let payloadSHA256: String
    let noncontiguousSender: Bool
    let nativeBytesExact: Bool
}

func checkStagePointToPointControls(collective: Collective,
                                   check: () throws -> Void) throws -> [StagePointToPointControlRecord] {
    var rows: [StagePointToPointControlRecord] = []
    for index in 0...StagePointToPointFixture.controlDTypes.count {
        let noncontiguous = index == StagePointToPointFixture.controlDTypes.count
        let dtype = noncontiguous ? DType.float32 : StagePointToPointFixture.controlDTypes[index]
        let original = try StagePointToPointFixture.bytes(dtype: dtype, count: 6)
        var expected = original
        if noncontiguous {
            expected = Data()
            for source in [0, 2, 4, 1, 3, 5] {
                expected.append(original.subdata(in: (source * dtype.size)..<((source + 1) * dtype.size)))
            }
        }
        let shape = [2, 3]
        let record = StagePointToPointControlRecord(caseID: "control-\(index)", dtype: String(describing: dtype),
            shape: shape, byteCount: expected.count, payloadSHA256: sha256(expected),
            noncontiguousSender: noncontiguous, nativeBytesExact: true)
        let identity = try canonicalJSONData(record)
        try autoreleasepool {
            if collective.rank == 0 {
                let input = noncontiguous
                    ? MLXArray(original, [3, 2], dtype: dtype).transposed()
                    : MLXArray(original, shape, dtype: dtype)
                eval(input); Stream.gpu.synchronize(); try check()
                if noncontiguous {
                    guard let storage = try input.evaluatedBufferInfo(), !storage.isRowContiguous else {
                        throw ProbeError("Noncontiguous transfer fixture became contiguous before send")
                    }
                }
                guard input.asData().data == expected else { throw ProbeError("Control sender logical bytes differ") }
                _ = try collective.sendCompleted(input, to: 1, maximumBytes: expected.count, check: check)
                let ack = try collective.receiveCompleted(shape: [64], dtype: .int32, from: 1,
                    maximumBytes: 256, check: check).asArray(Int32.self)
                try QwenLayerStageWireAcknowledgement.validate(ack, header: identity, phase: .consumed)
            } else {
                let input = try collective.receiveCompleted(shape: shape, dtype: dtype, from: 0,
                    maximumBytes: expected.count, check: check)
                guard input.asData().data == expected else { throw ProbeError("Control receive changed native bytes") }
                try check()
                let ack = QwenLayerStageWireAcknowledgement.values(header: identity, phase: .consumed)
                _ = try collective.sendCompleted(MLXArray(ack), to: 0, maximumBytes: 256, check: check)
            }
        }
        rows.append(record)
    }
    return rows
}

func checkStagePointToPointGeometry() throws {
    var accepted = 0, rejected = 0
    for dtype in StagePointToPointFixture.controlDTypes {
        let shape = try CollectivePointToPointShape(shape: [2, 3], dtype: dtype, maximumBytes: 24)
        guard shape.byteCount == 6 * dtype.size else { throw ProbeError("Point-to-point geometry byte accounting differs") }
        accepted += 1
    }
    for (shape, dtype, cap) in [([Int](), DType.float32, 16), ([0], .float32, 16),
        ([-1], .float32, 16), ([1, 1, 1, 1, 1], .float32, 16),
        ([Int(Int32.max) + 1], .float32, 16),
        ([Int(Int32.max), Int(Int32.max), Int(Int32.max)], .float32, 16),
        ([Int(Int32.max), Int(Int32.max)], .float32, 16),
        ([5], .float32, 16), ([1], .float32, 0),
        ([1], .float32, CollectivePointToPointShape.hardByteLimit + 1),
        ([1], .float64, 16), ([1], .bool, 16)] {
        do { _ = try CollectivePointToPointShape(shape: shape, dtype: dtype, maximumBytes: cap) }
        catch { rejected += 1; continue }
        throw ProbeError("Point-to-point shape admitted unsupported geometry")
    }
    let header = Data("header".utf8)
    let ready = QwenLayerStageWireAcknowledgement.values(header: header, phase: .ready)
    try QwenLayerStageWireAcknowledgement.validate(ready, header: header, phase: .ready)
    for (actual, other, phase) in [(ready, header, QwenLayerStageWireAcknowledgement.Phase.consumed),
        (ready, Data("other".utf8), .ready), (Array(ready.dropLast()), header, .ready)] {
        do { try QwenLayerStageWireAcknowledgement.validate(actual, header: other, phase: phase) }
        catch { rejected += 1; continue }
        throw ProbeError("Point-to-point acknowledgement admitted a stale or different transition")
    }
    struct Result: Encodable {
        let kind = "stage_p2p_geometry_check", cpuOnly = true
        let acceptedFixtures: Int, rejectedFixtures: Int
    }
    try emitJSON(Result(acceptedFixtures: accepted, rejectedFixtures: rejected))
}
