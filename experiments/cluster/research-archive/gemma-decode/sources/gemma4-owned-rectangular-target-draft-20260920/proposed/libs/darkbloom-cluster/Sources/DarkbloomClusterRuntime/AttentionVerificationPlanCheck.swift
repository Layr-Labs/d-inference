#if CBV2_WINDOW_STATE_FIXTURE
import Foundation

enum AttentionVerificationPlanCheck {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ProbeError(message) }
    }
    static func refuses(_ body: () throws -> Void) throws {
        var refused = false
        do { try body() } catch { refused = true }
        try require(refused, "Invalid rectangular plan was accepted")
    }
    static func run() throws -> [String] {
        func layout(_ dtype: LayerAttentionStateLayout.Element, chunk: Int = 64) throws -> LayerAttentionStateLayout {
            try .init(layers: (0..<30).map { index in
                let full = index % 6 == 5
                return .init(globalIndex: index, kvHeads: full ? 2 : 8,
                    headDimension: full ? 512 : 256, window: full ? nil : 1024, element: dtype)
            }, maximumTokens: 4224, maximumChunkTokens: chunk)
        }
        for dtype in [LayerAttentionStateLayout.Element.bfloat16, .float32] {
            let geometry = try layout(dtype)
            for base in [4096, 4219, 4220] {
                for width in 1...4 {
                    let plan = try CBv2AttentionVerificationPlan(layout: geometry, base: base, steps: width,
                        captureLayerIndices: [28, 29])
                    let pairPerToken = 2 * 8 * 256 * dtype.bytes
                    let staged = 25 * width * pairPerToken
                    let windows = 25 * (width + 1024 + width + 1024) * pairPerToken
                    let captures = (2 * 1024 * 2 * 8 * 256 + 4224 * 2 * 2 * 512) * dtype.bytes
                    try require(plan.stagedWindowBytes == staged
                        && plan.backendCapacityBytes == geometry.conservativeKVCapacityBytes + staged
                        && plan.additionalLogicalBytes == windows + captures
                        && plan.additionalArrays.count == 156
                        && Set(plan.additionalArrays.map(\.name)).count == 156
                        && plan.layout == geometry, "Gemma named state ledger differs from independent formula")
                    let same = try CBv2AttentionVerificationPlan(layout: geometry, base: base, steps: width,
                        captureLayerIndices: [28, 29])
                    try require(plan.fingerprint == same.fingerprint && plan.fingerprint != geometry.fingerprint,
                        "Ordinary and verification identities were conflated")
                }
            }
        }
        let geometry = try layout(.bfloat16)
        for tuple in [(0, 1), (4096, 0), (4096, 5), (4222, 3), (4224, 1)] {
            try refuses { _ = try CBv2AttentionVerificationPlan(layout: geometry, base: tuple.0,
                steps: tuple.1, captureLayerIndices: []) }
        }
        for indices in [[28, 28], [-1], [30], [0, 1, 2]] {
            try refuses { _ = try CBv2AttentionVerificationPlan(layout: geometry, base: 4096,
                steps: 4, captureLayerIndices: indices) }
        }
        let smallChunk = try layout(.bfloat16, chunk: 3)
        try refuses { _ = try CBv2AttentionVerificationPlan(layout: smallChunk, base: 4096,
            steps: 4, captureLayerIndices: []) }
        let a = try CBv2AttentionVerificationPlan(layout: geometry, base: 4096, steps: 4, captureLayerIndices: [])
        let b = try CBv2AttentionVerificationPlan(layout: geometry, base: 4097, steps: 4, captureLayerIndices: [])
        let c = try CBv2AttentionVerificationPlan(layout: geometry, base: 4096, steps: 3, captureLayerIndices: [])
        let d = try CBv2AttentionVerificationPlan(layout: geometry, base: 4096, steps: 4, captureLayerIndices: [28, 29])
        try require(Set([a.fingerprint, b.fingerprint, c.fingerprint, d.fingerprint]).count == 4,
            "Frontier, width or captures lost their verification identity")
        return ["gemma-25-window-5-full-bf16-f32-ledger", "p4096-o128-width1-through4",
            "per-array-capture-staging-commit-charge", "unchanged-context-chunk-refusals",
            "capture-coverage-refusals", "ordinary-and-verification-identities"]
    }
}
#endif
