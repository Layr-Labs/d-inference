import Foundation

// Explicit CPU metadata doubles, not native allocation or OS admission evidence.
// The actual cached and exact type-renamed uncached owner execute unchanged.
enum QwenResidentResourceEnvironment {
    static func allocationBound(_ bytes: Int) throws -> Int {
        guard bytes > 0 else { throw ProbeError("Fixture nonpositive allocation") }
        let extra = bytes % 16_384 == 0 ? 0 : 16_384-bytes%16_384
        return try QwenLongPrefillCheckedBytes.sum([bytes,extra])
    }
}
struct QwenDenseStageLoadOSObservation {
    let pressureLevel: Int, actualFreeBytes: Int
}
struct QwenDenseStageLoadNativeObservation { let activeBytes: Int }
struct Gemma4MTPRemoteTargetBudget {
    struct Term: Encodable, Equatable { let name: String, logicalBytes: Int, allocationBound: Int }
    let requestSHA256 = String(repeating:"a",count:64)
    let maximumFrontier = 143, serialTargetHead = true
    let terms: [Term] = [.init(name:"fixture-base",logicalBytes:65_536,allocationBound:65_536)]
    let nativeBytes = 65_536, hostBytes = 4096
    let fingerprint = String(repeating:"b",count:64)
}
struct CBv2AttentionVerificationPlan {
    struct Layout {
        struct Layer { let globalIndex: Int }
        let layers = (0..<30).map { Layer(globalIndex:$0) }
        let maximumTokens = 144
    }
    struct ArrayTerm { let name: String, bytes: Int }
    let layout = Layout()
    let captureLayerIndices = [28,29]
    let steps: Int
    let additionalArrays: [ArrayTerm]
}
struct Gemma4MTPPullTransferPlan {
    struct Term { let name: String, bytes: Int }
    let frontier: Int, senderAdditional: [Term]
}
