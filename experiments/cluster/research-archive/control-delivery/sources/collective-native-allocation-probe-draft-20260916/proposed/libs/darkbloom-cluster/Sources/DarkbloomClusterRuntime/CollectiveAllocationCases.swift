#if COLLECTIVE_RECORD_ALLOCATION_CHECK
import Foundation
import MLX

struct CollectiveAllocationCase {
    enum Failure: String { case none, ciphertext, tag, beforeExport, afterSeal, afterReceive, afterOpen, oversize, shape }
    struct Geometry {
        let id: String
        let shape: [Int]
        let dtype: DType
        var bytes: Int { shape.reduce(1, *) * dtype.size }
    }
    let id: String
    let geometries: [Geometry]
    let rounds: Int
    let failure: Failure
    let sessionOnly: Bool
    let priming: [Geometry]
    init(id: String, geometries: [Geometry], rounds: Int, failure: Failure, sessionOnly: Bool, priming: [Geometry] = []) {
        self.id = id; self.geometries = geometries; self.rounds = rounds
        self.failure = failure; self.sessionOnly = sessionOnly; self.priming = priming
    }
    static let maximumPlaintextBytes = 512 * 5120 * 4
    static let maximumFrameBytes = maximumPlaintextBytes + 40

    static var all: [Self] {
        let scalar = Geometry(id: "u32-4", shape: [1], dtype: .uint32)
        let ack = Geometry(id: "i32-256", shape: [64], dtype: .int32)
        let tiny = Geometry(id: "u8-1", shape: [1], dtype: .uint8)
        var shapes = [scalar, ack, tiny, .init(id: "u8-4096", shape: [4096], dtype: .uint8),
            .init(id: "u8-16384", shape: [16384], dtype: .uint8)]
        for (label, dtype) in [("bf16", DType.bfloat16), ("f32", DType.float32)] {
            for hidden in [4096, 5120] {
                for chunk in [1, 511, 512] {
                    shapes.append(.init(id: "\(label)-\(chunk)x\(hidden)", shape: [1, chunk, hidden], dtype: dtype))
                }
            }
        }
        let largest = shapes.last!
        var cases = shapes.map { Self(id: "fresh-" + $0.id, geometries: [$0], rounds: 32, failure: .none, sessionOnly: false) }
        cases.append(.init(id: "reuse-large-short", geometries: [largest, scalar, ack, largest, tiny], rounds: 8, failure: .none, sessionOnly: false))
        for failure in [Failure.ciphertext, .tag, .beforeExport, .afterSeal, .afterReceive, .afterOpen, .oversize, .shape] {
            cases.append(.init(id: "failure-" + failure.rawValue, geometries: [largest], rounds: 1, failure: failure, sessionOnly: false))
            cases.append(.init(id: "reused-failure-" + failure.rawValue, geometries: [largest], rounds: 1,
                failure: failure, sessionOnly: false, priming: [largest, scalar, ack]))
        }
        cases.append(.init(id: "session-only", geometries: [], rounds: 1, failure: .none, sessionOnly: true))
        return cases
    }
    static func find(_ id: String) throws -> Self {
        guard let value = all.first(where: { $0.id == id }) else { throw ProbeError("Unknown fixed allocation case") }
        return value
    }
}
#endif
