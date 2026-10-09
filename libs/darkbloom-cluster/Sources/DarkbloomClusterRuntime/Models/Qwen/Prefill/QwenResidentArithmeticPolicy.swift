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

    static let expertSlicesName = "MLX_GATHER_QMM_EXPERT_SLICES"
    static let expertSlicesValue = "trust"
    static let directReductionName = "MLX_QWEN_DIRECT_EXPERT_REDUCTION"

    var contract: String {
        switch self {
        case .dense: QwenLongPrefillArithmeticEnvironment.contract
        case .routedExperts: "qwen_cbv2_query128_bf16_tf32_expert_tiles_v1"
        }
    }

    var requiredValues: [String: String] {
        var values = QwenLongPrefillArithmeticEnvironment.requiredValues
        if self == .routedExperts { values[Self.expertSlicesName] = Self.expertSlicesValue }
        return values
    }

    var requiredAbsentNames: [String] {
        QwenLongPrefillArithmeticEnvironment.requiredAbsentNames
            + (self == .routedExperts ? [Self.directReductionName] : [])
    }

    func admit(_ environment: [String: String]) throws -> QwenLongPrefillArithmeticEnvironment.Receipt {
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
