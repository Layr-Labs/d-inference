import DarkbloomClusterProtocol
import Foundation
import MLXLMCommon

/// What two ranks of a Gemma 4 tensor-parallel pair bind into their load
/// agreement besides the registered row's own fingerprint
/// (`Gemma4ResidentAdmission.loadAgreementFingerprint`: membership, model,
/// artifact, manifest, cut plan, profile, arithmetic receipt, JACCL,
/// allocator policy, both builds and the prefill schedule). The agreement
/// keys the pair's data plane and is compared before any weight is read, so
/// a rank started with any other value here refuses its peer.
struct Gemma4TensorParallelLoadAgreement: Equatable {
    static let schema = "gemma4-tensor-parallel-load-v1"

    /// Requests served at once; one serves one request at a time.
    var lanes = 1
    var kv = ClusterStageKVBackendKind.paged
    var kvQuantization = PagedKVQuantizationSelection.native
    /// Prompt prefixes kept, resident and on the SSD tier (`Gemma4TensorParallelPrefix`):
    /// this build's `tensorParallelKeepsPromptPrefixes`, unless the diagnosis switch
    /// turns them off on a rank, which its peer then refuses.
    var prefixCache = Gemma4ResidentAdapterDefinition.tensorParallelKeepsPromptPrefixes

    /// The mode's terms (FP32 partials, rounded once after the sum; the
    /// sealed all-sum) and the plan's: where each layer's two sums are taken
    /// and what they carry (the attention partial; one packed collective of
    /// the dense partial and every selected expert's row).
    static var termsFields: [String] {
        ClusterGenerationMode.tensorParallel.loadAgreementFields + Gemma4TensorParallelPlan.arithmeticAgreementFields
    }

    /// The registered prompt policy (singleton token reduction of every
    /// affine projection, the product's CBv2 prompt path with its final-layer
    /// tail) on the request's own chunk grid, and the decode step.
    static let promptPolicyFields = ["gemma4-tensor-parallel-prompt-v1", "token-m1-affine-projections",
                                     "cbv2-prompt-final-layer-tail", "request-chunk-grid", "decode-one-token-a-step"]

    /// How a token is chosen and its logprobs captured
    /// (`Gemma4TensorParallelChoice`).
    static let selectionFields = ["gemma4-tensor-parallel-selection-v1", "greedy-split-argmax-carrying-stops",
                                  "sampled-gathered-row-rank0-draw", "logprobs-split-top-k"]

    var fields: [String] {
        Self.termsFields + Self.promptPolicyFields + Self.selectionFields
            + ["gemma4-tensor-parallel-lanes-v1", String(lanes)]
            + kv.loadAgreementFields + kvQuantization.loadAgreementFields
            + ["gemma4-tensor-parallel-prefix-v1", prefixCache ? "on" : "off"]
            + ClusterDataPlaneAgreement.loadAgreementFields
    }

    /// The agreement both ranks compare: this rank's registered row's
    /// fingerprint and every field above.
    func fingerprint(admission: String) throws -> String {
        sha256(try canonicalJSONData([Self.schema, admission] + fields))
    }
}
