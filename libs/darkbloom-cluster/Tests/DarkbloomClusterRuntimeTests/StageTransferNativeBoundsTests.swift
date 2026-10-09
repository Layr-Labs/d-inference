import MLX
import Testing
@testable import DarkbloomClusterRuntime

// The stage transfer plan is computed without MLX, so it restates two facts
// about the native side. These tests hold the restatements to the originals.

@Suite("Stage transfer plan against the native transport")
struct StageTransferNativeBoundsTests {
    @Test func pieceLimitIsThePointToPointReceiveCap() {
        #expect(QwenStageTransferLimits.hardPieceByteLimit == CollectivePointToPointShape.hardByteLimit)
        #expect(QwenStageTransferLimits.proposed.pieceByteLimit <= CollectivePointToPointShape.hardByteLimit)
    }

    @Test func storedDTypesAreNativeDTypesTheTransportCarries() {
        let pairs: [(QwenStageStoredDType, DType)] = [
            (.uint32, .uint32), (.float32, .float32), (.float16, .float16), (.bfloat16, .bfloat16),
        ]
        #expect(pairs.count == QwenStageStoredDType.allCases.count)
        for (stored, native) in pairs {
            // The spelling the loader's records and receipts use.
            #expect(stored.nativeName == String(describing: native))
            #expect(stored.elementBytes == native.size)
            #expect(QwenStageStoredDType(nativeName: String(describing: native)) == stored)
            #expect(CollectivePointToPointShape.allowedDTypes.contains(native))
        }
    }

    @Test func everyPlannedPieceIsAnAdmissiblePointToPointShape() throws {
        let active = [
            QwenStageActiveTensor(sourceName: "a", localName: "a", shape: [70, 3, 2, 2], sourceDType: "bfloat16",
                                  loadedDType: "bfloat16", byteCount: 1680),
            QwenStageActiveTensor(sourceName: "b", localName: "b", shape: [5], sourceDType: "float32",
                                  loadedDType: "float32", byteCount: 20),
        ]
        let limits = try QwenStageTransferLimits(pieceByteLimit: 256, windowByteLimit: 512, windowPieceLimit: 4)
        let plan = try QwenStageTransferPlan(stages: [.init(stageIndex: 1, active: active)], limits: limits)
        #expect(plan.pieces.count > 2)
        for piece in plan.pieces {
            let dtype: DType = piece.dtype == .bfloat16 ? .bfloat16 : .float32
            let shape = try CollectivePointToPointShape(shape: piece.shape, dtype: dtype,
                                                        maximumBytes: limits.pieceByteLimit)
            #expect(shape.byteCount == piece.byteCount)
        }
    }
}
