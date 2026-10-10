import Foundation

/// The arithmetic contract a registered model's ranks must be started under:
/// the exact process environment its forward arithmetic depends on. It is a
/// property of the model's resident row; both ranks hash their own receipt
/// into the load agreement, so ranks started under different environments
/// stop before either stage is read.
enum QwenResidentArithmeticPolicy: Equatable {
    /// `QwenLongPrefillArithmeticEnvironment`, unchanged.
    case dense
    /// The dense contract plus the routed experts' route: the sorted
    /// expert-tile gather the product serves these models with, in the
    /// product's own serving value, and never the opt-in direct reduction.
    /// The Metal kernels of that route come from the metallib beside the
    /// binary, which both ranks must hold identical.
    case routedExperts
    /// The dense contract plus the two switches the pinned SDK reads for a
    /// Prism Hadamard pack, each at the product's own serving default, and
    /// the process-wide constant-cache switch required absent.
    case prismHadamard
    /// Nemotron-H: the dense contract's three values and absent names under
    /// its own name, so a capability or a load agreement of this family is
    /// never mistaken for a Qwen one. Nothing is added to it, for this reason:
    /// the expert-tile gather route that `MLX_GATHER_QMM_EXPERT_SLICES`
    /// selects accepts only 4,096, 8,192 or 16,384 assignments and the Gemma 4
    /// and Qwen 35B expert shapes (pinned MLX,
    /// `mlx/backend/common/gemma4_expert_qmm.h`, `classify_gemma4_expert_qmm`,
    /// lines 108 to 171: the assignment counts at 140, the shapes at 149 to
    /// 166). Nemotron's 128 experts of 2688 to 1856 and 1856 to 2688 at top 6
    /// are neither (a 512-token chunk has 3,072 assignments), so its routed
    /// gathers take the ordinary kernel whatever that variable says. Its blocks use neither `SwitchGLU`
    /// nor a Qwen4 projection, so the direct-reduction and Qwen4 switches do
    /// not reach it, and the `DARKBLOOM_NEMOTRON35_MTP_*` switches act only
    /// on the speculative head, which no stage constructs.
    case nemotronHybrid

    static let expertSlicesName = "MLX_GATHER_QMM_EXPERT_SLICES"
    static let expertSlicesValue = "trust"
    static let directReductionName = "MLX_QWEN_DIRECT_EXPERT_REDUCTION"

    var contract: String {
        switch self {
        case .dense: QwenLongPrefillArithmeticEnvironment.contract
        case .routedExperts: "qwen_cbv2_query128_bf16_tf32_expert_tiles_v1"
        case .prismHadamard: QwenPrismArithmeticContract.contract
        case .nemotronHybrid: "nemotron_h_cbv2_query128_bf16_tf32_default_v1"
        }
    }

    var requiredValues: [String: String] {
        var values = QwenLongPrefillArithmeticEnvironment.requiredValues
        if self == .routedExperts { values[Self.expertSlicesName] = Self.expertSlicesValue }
        if self == .prismHadamard { values.merge(QwenPrismArithmeticContract.values) { current, _ in current } }
        return values
    }

    var requiredAbsentNames: [String] {
        QwenLongPrefillArithmeticEnvironment.requiredAbsentNames
            + (self == .routedExperts ? [Self.directReductionName] : [])
            + (self == .prismHadamard ? QwenPrismArithmeticContract.absentNames : [])
    }

    func admit(_ environment: [String: String]) throws -> QwenLongPrefillArithmeticEnvironment.Receipt {
        if self == .prismHadamard {
            return try QwenLongPrefillArithmeticEnvironment.admit(environment, contract: contract,
                additionalValues: QwenPrismArithmeticContract.values,
                additionalAbsentNames: QwenPrismArithmeticContract.absentNames,
                additionalBindings: QwenPrismArithmeticContract.bindings)
        }
        if self == .nemotronHybrid {
            return try QwenLongPrefillArithmeticEnvironment.admit(environment, contract: contract,
                additionalValues: [:], additionalAbsentNames: [], additionalBindings: [:])
        }
        guard self == .routedExperts else { return try QwenLongPrefillArithmeticEnvironment.admit(environment) }
        return try QwenLongPrefillArithmeticEnvironment.admit(environment, contract: contract,
            additionalValues: [Self.expertSlicesName: Self.expertSlicesValue],
            additionalAbsentNames: [Self.directReductionName],
            additionalBindings: [
                Self.expertSlicesName: "explicit trust is the product's serving value; sorted routed-expert gathers take the expert-tile route when the metallib carries its kernels",
                Self.directReductionName: "source default off; routed outputs are unsorted and summed by the stock weighted reduction",
            ])
    }
}
