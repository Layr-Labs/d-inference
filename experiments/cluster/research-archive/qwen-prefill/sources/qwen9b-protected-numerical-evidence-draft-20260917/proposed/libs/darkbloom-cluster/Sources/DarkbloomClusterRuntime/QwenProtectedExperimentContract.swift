import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation

/// A closed correctness experiment, not ordinary serving admission. The
/// executable, source/resource bundle and this description need external pins.
public enum QwenResidentProtectedExperiment {
    public static let identifier = "qwen9b_short_records_experiment_v1"
    static let cut = 16, prompt = 32, chunk = 16, outputs = 2
    static let maximumPlaintextBytes = 16 * 4096 * 2
    static let maximumFrameBytes = maximumPlaintextBytes + 40
    static let maximumRecords: UInt64 = 1024
    static let maximumCumulativeBytes: UInt64 = 16 * 1024 * 1024
    static let observedPhysicalIncrement = 71_532_640
    static let observedNativeIncrement = 20_987_904
    // MeshGroup::allocate_buffers: all eight sizes, two slots, world2 mesh
    // plus world4 scatter backing. Charge the unused scatter slots too.
    static let meshBackingBytes = 4096 * 255 * 2 * 6
    static let keyAndMetadataAllowance = 1_048_576
    static let operationalSafetyBytes = 64 * 1_048_576
    static let nativeAllowanceBytes = 32 * 1_048_576
    static let hostAllowanceBytes = observedPhysicalIncrement + meshBackingBytes
        + 4 * maximumFrameBytes + keyAndMetadataAllowance + operationalSafetyBytes
        + QwenProtectedEvidenceBudget.additionalHostBytes
    static let reservedBytes = hostAllowanceBytes + nativeAllowanceBytes
    static let evidence = [
        "14e970b06fc03dfff941c68d6998bc92ffac1b2478f32aea869a2fcfc3e291fe",
        "73be77f1f7dd00295476fe7f276655ab285cb485240a8479ab1a275fa36559d0",
    ]

    static func limits() throws -> ClusterRecordLimits {
        try .init(maximumPlaintextBytes: maximumPlaintextBytes,
            maximumRecordsPerDirection: maximumRecords,
            maximumCumulativePlaintextBytesPerDirection: maximumCumulativeBytes)
    }

    static func resourcePolicyBytes() throws -> Data {
        try canonicalJSONData(QwenProtectedResourcePolicyRecord(
            schema: "qwen9b_protected_operational_resources_v1",
            profile: identifier, hardwareModel: "Mac16,7", osBuild: "26A428",
            physicalMemoryBytes: [24 * 1_073_741_824, 48 * 1_073_741_824],
            allocatorPolicy: "disable_freed_buffer_cache_v1", suite: "aes256GcmHkdfSha256V1",
            maximumInFlightOperations: 1, separateDirectionCodecs: false,
            maximumPlaintextBytes: maximumPlaintextBytes, maximumFrameBytes: maximumFrameBytes,
            maximumRecordsPerDirection: maximumRecords,
            maximumCumulativePlaintextBytesPerDirection: maximumCumulativeBytes,
            observedPhysicalIncrementBytes: observedPhysicalIncrement,
            observedNativeIncrementBytes: observedNativeIncrement,
            meshBackingBytes: meshBackingBytes, logicalHostCopies: 4 * maximumFrameBytes,
            keyAndMetadataAllowanceBytes: keyAndMetadataAllowance,
            operationalSafetyBytes: operationalSafetyBytes,
            numericalEvidenceHostAllowanceBytes: QwenProtectedEvidenceBudget.additionalHostBytes,
            numericalEvidenceMaximumEncodedBytes: QwenProtectedEvidenceBudget.maximumEncodedBytes,
            numericalEvidenceSchema: "qwen9b_protected_final_evidence_v1",
            additionalHostBytes: hostAllowanceBytes, additionalNativeBytes: nativeAllowanceBytes,
            minimumActualFreeBytes: 6 * 1_073_741_824,
            loadingHeadroomBytes: 4 * 1_073_741_824, allocatorHeadroomBytes: 2 * 1_073_741_824,
            allocationReviews: evidence, sourceBindings: QwenProtectedSourceBindings.values,
            allocationNativeSHA256: "4f4149c7330d8268ac7294ef7b225db25078d2fb853cb06af1d02e73ae66b26c",
            wholeProcessPeakProven: false, rdmaMeasured: false, servingEnabled: false
        ))
    }

    static func requireWorkload(promptCount: Int, chunkSize: Int, outputCount: Int,
                                stopTokenIDs: [Int]) throws {
        guard promptCount == prompt, chunkSize == chunk, outputCount == outputs, stopTokenIDs.isEmpty else {
            throw ProbeError("Protected experiment requires P32/C16/O2 and empty stop IDs")
        }
    }

    /// Exact unchanged capability bytes remain separately hashed. No capability
    /// reader may infer encrypted support from its ordinary profile alone.
    public static func describe(configuration: Data, manifest: Data,
                                runtimeBinarySHA256: String) throws -> Data {
        let capability = try QwenResidentCapabilityMetadata.describe(configuration: configuration,
            manifest: manifest, runtimeBinarySHA256: runtimeBinarySHA256)
        let raw = try ClusterRuntimeCapabilityCodec.encode(capability)
        guard let plan = capability.partitions.first(where: {
            $0.stages.count == 2 && $0.stages[0].sourceLayerStart == 0
                && $0.stages[0].sourceLayerEnd == cut && $0.stages[1].sourceLayerStart == cut
        }) else { throw ProbeError("Protected cut is absent from the actual registered capability") }
        let policy = try resourcePolicyBytes()
        var result = try canonicalJSONData(QwenProtectedRuntimeDescriptionRecord(
            schema: "qwen9b_protected_runtime_description_v1", staticProfile: identifier,
            runtimeBinarySHA256: runtimeBinarySHA256,
            ordinaryCapabilityBase64: raw.base64EncodedString(), capabilitySHA256: sha256(raw),
            selectedPlanSHA256: plan.planSHA256, profileFingerprint: capability.profileFingerprint,
            resourcePolicySHA256: sha256(policy), resourcePolicyBase64: policy.base64EncodedString(),
            stageCut: cut, prefillSchedule: ClusterPrefillSchedule.serial.rawValue, promptTokens: prompt,
            chunkTokens: chunk, outputTokens: outputs, stopTokenIDs: [Int](),
            maximumPlaintextBytes: maximumPlaintextBytes, maximumFrameBytes: maximumFrameBytes,
            maximumRecordsPerDirection: maximumRecords,
            maximumCumulativePlaintextBytesPerDirection: maximumCumulativeBytes,
            bootstrapProfile: "native_key_prelude_mesh2_v1", sourceBindings: QwenProtectedSourceBindings.values,
            allocationReviews: evidence, experimentalExecutionOnly: true,
            wholeProcessPeakProven: false, rdmaMeasured: false, servingEnabled: false
        ))
        guard result.count < 32 * 1024 else { throw ProbeError("Protected description exceeds its bound") }
        result.append(10); return result
    }
}
