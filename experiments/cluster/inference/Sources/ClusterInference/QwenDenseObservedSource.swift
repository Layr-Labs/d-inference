import Foundation

/// Projection of actual PreparedQwenCheckpoint/model metadata by the bridge.
/// It is untrusted CPU input until validation, not a payload/OS attestation.
struct QwenDenseObservedSourceTensor {
    let canonical: QwenDenseCanonicalTensor
    let sourcePartCount: Int
    let preparedExpectedShape: [Int]?
    let constructorParameterIsPacked: Bool?
}

struct QwenDenseObservedSourceIdentity {
    let aggregateSHA256: String, configurationSHA256: String, verifiedManifestSHA256: String?
    let retainedSourceCount: Int
    let bf16ConversionEnabled: Bool
}

struct QwenDenseValidatedSourceTensor {
    let canonical: QwenDenseCanonicalTensor
    let loadedDType: String
    var layoutEntry: String { "\(canonical.name):\(loadedDType):\(canonical.shape)" }
}

/// Internal scalar read plan only. No new JSON proof, array, descriptor handle
/// or materialization permit is introduced. Registered plans remain metadata.
struct QwenDenseSourceReadPlan {
    let tensors: [QwenDenseValidatedSourceTensor]
    let sourceBytes: Int, largestSourceBytes: Int
    let expectedLayoutSHA256: String
    let registeredProfileFingerprint: String?, registeredRequirementFingerprint: String?
    let runtimeExecutionAuthorized = false

    fileprivate init(tensors: [QwenDenseValidatedSourceTensor], sourceBytes: Int,
                     largestSourceBytes: Int, profile: String?, requirement: String?) {
        self.tensors = tensors; self.sourceBytes = sourceBytes; self.largestSourceBytes = largestSourceBytes
        self.expectedLayoutSHA256 = QwenDenseProfileIdentity.fingerprint(tensors.map(\.layoutEntry).sorted())
        self.registeredProfileFingerprint = profile; self.registeredRequirementFingerprint = requirement
    }
}

enum QwenDenseLegacySourcePurpose { case diagnostic, layerStage }

enum QwenDenseObservedSourceValidation {
    static func validateLegacy(_ observed: [QwenDenseObservedSourceTensor], convertBF16: Bool,
                               purpose: QwenDenseLegacySourcePurpose) throws -> QwenDenseSourceReadPlan {
        try validate(observed, convertBF16: convertBF16,
            sourceLimit: QwenDenseLegacySourceBounds.maximumSourceModelTensorBytes,
            hostLimit: QwenDenseLegacySourceBounds.maximumHostTensorBytes, purpose: purpose,
            profile: nil, requirement: nil)
    }

    /// No materializer calls this branch in the proposed bridge. Actual raw
    /// manifest/artifact verification and descriptor projection must precede a
    /// future call; matching caller strings alone never authorizes execution.
    static func validateRegistered(_ observed: [QwenDenseObservedSourceTensor],
        identity: QwenDenseObservedSourceIdentity, profile: QwenRegisteredDenseModelProfile,
        requirement: QwenDenseStorageRequirement, plan: QwenLayerStagePlan
    ) throws -> QwenDenseSourceReadPlan {
        guard observed.count == profile.canonicalTensors.count else {
            throw ProbeError("Observed registered source count differs from its complete descriptor inventory")
        }
        let rebuilt = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: requirement.role)
        guard rebuilt.fingerprint == requirement.fingerprint,
              identity.aggregateSHA256 == profile.artifactAggregateSHA256,
              identity.configurationSHA256 == profile.configurationSHA256,
              identity.verifiedManifestSHA256 == profile.manifestSHA256,
              identity.retainedSourceCount == profile.canonicalTensors.count,
              identity.bf16ConversionEnabled == profile.requiredBF16ConversionPolicy else {
            throw ProbeError("Observed registered source identity, retained count, Plan or role differs")
        }
        let result = try validate(observed, convertBF16: profile.requiredBF16ConversionPolicy,
            sourceLimit: profile.sourceTensorBytes, hostLimit: profile.largestSourceTensorBytes,
            purpose: .layerStage, profile: profile.fingerprint, requirement: requirement.fingerprint)
        let actual = result.tensors.map(\.canonical)
        guard actual == profile.canonicalTensors, result.sourceBytes == profile.sourceTensorBytes,
              result.largestSourceBytes == profile.largestSourceTensorBytes else {
            throw ProbeError("Actual canonical source differs from the complete registered descriptor inventory")
        }
        return result
    }

    private static func validate(_ observed: [QwenDenseObservedSourceTensor], convertBF16: Bool,
        sourceLimit: Int, hostLimit: Int, purpose: QwenDenseLegacySourcePurpose,
        profile: String?, requirement: String?
    ) throws -> QwenDenseSourceReadPlan {
        let sorted = observed.sorted { $0.canonical.name < $1.canonical.name }
        guard Set(sorted.map { $0.canonical.name }).count == sorted.count else {
            throw ProbeError("Observed canonical source repeats a name")
        }
        var records: [QwenDenseValidatedSourceTensor] = [], total = 0, largest = 0
        for observed in sorted {
            let tensor = observed.canonical
            guard observed.sourcePartCount == 1, tensor.byteCount > 0, tensor.byteCount <= hostLimit,
                  tensor.shape == observed.preparedExpectedShape,
                  let packed = observed.constructorParameterIsPacked,
                  (tensor.sourceDType == "U32") == packed,
                  ["U32", "F16", "BF16", "F32"].contains(tensor.sourceDType) else {
                switch purpose {
                case .diagnostic:
                    throw ProbeError("Verified diagnostic requires bounded, exact full tensor shapes and dtypes: \(tensor.name)")
                case .layerStage:
                    throw ProbeError("Stage source requires exact bounded full tensor shape/dtype: \(tensor.name)")
                }
            }
            // Verified TensorDescriptor already checked shape products. Keep
            // the legacy pre-materialization shape/class/one-part semantics;
            // registered equality independently fixes every descriptor byte.
            let next = total.addingReportingOverflow(tensor.byteCount)
            guard !next.overflow, next.partialValue <= sourceLimit else {
                if profile != nil { throw ProbeError("Observed registered source exceeds its exact descriptor byte limit") }
                switch purpose {
                case .diagnostic: throw ProbeError("Verified diagnostic canonical source exceeds the 6 GiB byte limit")
                case .layerStage: throw ProbeError("Layer-stage canonical source exceeds 6 GiB")
                }
            }
            total = next.partialValue; largest = max(largest, tensor.byteCount)
            let dtype: String
            switch tensor.sourceDType {
            case "U32": dtype = "uint32"
            case "F32": dtype = "float32"
            case "BF16": dtype = "bfloat16"
            case "F16": dtype = convertBF16 ? "bfloat16" : "float16"
            default: throw ProbeError("Unsupported observed source dtype")
            }
            records.append(.init(canonical: tensor, loadedDType: dtype))
        }
        guard total > 0 else {
            switch purpose {
            case .diagnostic: throw ProbeError("Verified diagnostic has no canonical tensors")
            case .layerStage: throw ProbeError("Every canonical source tensor must have exactly one layer-stage owner")
            }
        }
        return .init(tensors: records, sourceBytes: total, largestSourceBytes: largest,
                     profile: profile, requirement: requirement)
    }
}
