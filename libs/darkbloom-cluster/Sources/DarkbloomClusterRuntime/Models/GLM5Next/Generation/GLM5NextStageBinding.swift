import Foundation
import MLXLLM

/// A complete two-rank construction contract derived from a verified SDK owner.
/// The caller's manifest aggregate/storage commitment remain authoritative; the
/// file identity hash binds those claims to the exact owner used for each load.
struct GLM5NextStageContract {
    let source: QwenLayerStageWireSourceIdentity
    let stageFingerprints: [String]
    let constructionConfigurationSHA256: String
    let numericalPolicySHA256: String

    private let configuration: GLM5NextConfiguration
    private let executionPolicy: GLM5NextExecutionPolicy
    private let storage: GLM5NextWeightInventory.Storage
    private let artifactIdentitySHA256: String
    private let plans: [GLM5NextTextStagePlan]

    init(loader: GLM5NextArtifactLoader, artifactAggregateSHA256: String,
         storageCommitmentSHA256: String, cut: Int, loadMTPEmbedding: Bool = false) throws {
        let metadata = try GLM5NextStageContractMetadata(
            configuration: loader.configuration, artifactIdentity: loader.identity,
            storage: loader.inventory.storage, executionPolicy: loader.executionPolicy,
            artifactAggregateSHA256: artifactAggregateSHA256,
            storageCommitmentSHA256: storageCommitmentSHA256,
            cut: cut, loadMTPEmbedding: loadMTPEmbedding)
        source = metadata.source
        stageFingerprints = metadata.stageFingerprints
        constructionConfigurationSHA256 = metadata.constructionConfigurationSHA256
        numericalPolicySHA256 = metadata.numericalPolicySHA256
        configuration = metadata.configuration
        executionPolicy = metadata.executionPolicy
        storage = metadata.storage
        artifactIdentitySHA256 = metadata.artifactIdentitySHA256
        plans = metadata.plans
    }

    /// No arbitrary model/receipt pair can mint a binding. Only the SDK's verified
    /// load returns the model retained by this receipt. Admission remains with the
    /// caller and runs through the SDK hook before each tensor allocation.
    func loadStage(using loader: GLM5NextArtifactLoader, stageIndex: Int,
                   beforeTensorRead: ((String, Int) throws -> Void)? = nil) throws -> GLM5NextStageBinding {
        guard plans.indices.contains(stageIndex),
              try GLM5NextStageContractMetadata.artifactHash(loader.identity) == artifactIdentitySHA256,
              loader.configuration == configuration,
              loader.inventory.storage == storage,
              loader.executionPolicy == executionPolicy else {
            throw ProbeError("GLM load owner differs from its source/configuration/policy contract")
        }
        let model = try loader.loadTextStage(plan: plans[stageIndex], beforeTensorRead: beforeTensorRead)
        try validate(model: model, stageIndex: stageIndex)
        return .init(model: model, contract: self, stageIndex: stageIndex)
    }

    fileprivate func validate(model: GLM5NextTextStage, stageIndex: Int) throws {
        guard plans.indices.contains(stageIndex) else { throw ProbeError("GLM stage rank is invalid") }
        let plan = plans[stageIndex]
        guard model.plan.configuration == configuration.textConfig,
              model.inventory.configuration == configuration, model.inventory.storage == storage,
              model.plan.layers == plan.layers, model.plan.loadsMTPEmbedding == plan.loadsMTPEmbedding,
              model.executionPolicy == executionPolicy,
              model.layers.count == plan.layers.count,
              (model.embedding != nil) == plan.loadsEmbedding,
              (model.norm != nil) == plan.isFinal, (model.head != nil) == plan.isFinal else {
            throw ProbeError("GLM loaded stage differs from its exact construction contract")
        }
    }

    /// Versioned stable wire spelling, independent of Swift reflection, enum
    /// descriptions and randomized Hashable. Exhaustive switches cover every
    /// policy choice, including the nested sparse-selection controls.
    static func policySHA256(_ policy: GLM5NextExecutionPolicy) throws -> String {
        var fields = [
            "schema": "glm5-next-execution-policy-v1",
            "sparseSelection.deviceRanges": policy.sparseSelection.deviceRanges ? "true" : "false",
            "sparseSelection.queryBlocks": policy.sparseSelection.queryBlocks ? "true" : "false",
        ]
        fields["sparseAttention"] = switch policy.sparseAttention {
        case .reference: "reference"
        case .absorbed: "absorbed"
        case .absorbedDenseHistory: "absorbedDenseHistory"
        }
        fields["sparseSelection.selection"] = switch policy.sparseSelection.selection {
        case .reference: "reference"
        case .parallelThreshold: "parallelThreshold"
        }
        fields["pagedMetadataReads"] = switch policy.pagedMetadataReads {
        case .hostRecords: "hostRecords"
        case .deviceTable: "deviceTable"
        }
        fields["hyperConnection"] = switch policy.hyperConnection {
        case .reference: "reference"
        case .nativeRequired: "nativeRequired"
        case .nativeNormFused: "nativeNormFused"
        }
        fields["routedExperts"] = switch policy.routedExperts {
        case .reference: "reference"
        case .nativeCombine: "nativeCombine"
        case .nativeCombineSortedPrefill: "nativeCombineSortedPrefill"
        case .fusedDecode: "fusedDecode"
        case .fusedDecodeNAXPrefill: "fusedDecodeNAXPrefill"
        }
        fields["linearAttention"] = switch policy.linearAttention {
        case .reference: "reference"
        case .nativeRecurrence: "nativeRecurrence"
        case .nativeRecurrenceChunkedPrefill: "nativeRecurrenceChunkedPrefill"
        }
        fields["normalization"] = switch policy.normalization {
        case .reference: "reference"
        case .fusedKernel: "fusedKernel"
        }
        fields["linearDecodeStep"] = switch policy.linearDecodeStep {
        case .composed: "composed"
        case .fusedKernel: "fusedKernel"
        case .fusedEveryStep: "fusedEveryStep"
        }
        fields["routing"] = switch policy.routing {
        case .reference: "reference"
        case .nativeKernel: "nativeKernel"
        case .nativeKernelPrefill: "nativeKernelPrefill"
        }
        fields["projections"] = switch policy.projections {
        case .separate: "separate"
        case .fusedInputs: "fusedInputs"
        }
        fields["stepEvaluation"] = switch policy.stepEvaluation {
        case .deferred: "deferred"
        case .earlyAsync: "earlyAsync"
        }
        fields["sparseDecode"] = switch policy.sparseDecode {
        case .reference: "reference"
        case .nativeKernels: "nativeKernels"
        }
        fields["sparsePrefill"] = switch policy.sparsePrefill {
        case .reference: "reference"
        case .nativeKernel: "nativeKernel"
        }
        fields["prefillProjections"] = switch policy.prefillProjections {
        case .mlx: "mlx"
        case .nativeGEMM: "nativeGEMM"
        }
        return sha256(try canonicalJSONData(fields))
    }
}

/// Non-Module ownership prevents a module cycle and keeps the exact SDK-loaded
/// instance paired with its receipt. Constructed only by the contract's loader.
struct GLM5NextStageBinding {
    let model: GLM5NextTextStage
    let contract: GLM5NextStageContract
    let stageIndex: Int

    fileprivate init(model: GLM5NextTextStage, contract: GLM5NextStageContract, stageIndex: Int) {
        self.model = model; self.contract = contract; self.stageIndex = stageIndex
    }

    func identity(for agreement: QwenLayerStageGenerationAgreement) throws -> QwenLayerStageSessionIdentity {
        try contract.validate(model: model, stageIndex: stageIndex)
        let descriptor = agreement.descriptor, source = contract.source
        guard descriptor.sourceConfigurationSHA256 == source.sourceConfigurationSHA256,
              descriptor.artifactAggregateSHA256 == source.artifactAggregateSHA256,
              descriptor.storageCommitmentSHA256 == source.storageCommitmentSHA256,
              descriptor.planFingerprint == source.planFingerprint,
              descriptor.stageFingerprints == contract.stageFingerprints,
              descriptor.numericalPolicySHA256 == contract.numericalPolicySHA256 else {
            throw ProbeError("GLM stage contract differs from the negotiated agreement")
        }
        return .init(stageIndex: stageIndex, requestFingerprint: agreement.request.fingerprint,
            artifactAggregateSHA256: source.artifactAggregateSHA256,
            storageCommitmentSHA256: source.storageCommitmentSHA256, bf16ConversionEnabled: false,
            sourceConfigurationSHA256: source.sourceConfigurationSHA256,
            constructionConfigurationSHA256: contract.constructionConfigurationSHA256,
            planFingerprint: source.planFingerprint, stageFingerprint: contract.stageFingerprints[stageIndex],
            activationDType: model.plan.configuration.dtype)
    }
}
