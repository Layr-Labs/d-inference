import Foundation
import CoreFoundation
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
import DarkbloomClusterSecurity

/// A verified metadata observation, never native readiness or runtime approval.
/// Its initializer is private; the saved label alone cannot create this value.
struct DistributedInstalledNativeAttachment: Sendable {
    let attachment: ClusterNativeMemberAttachment
    private let inputs: [DistributedInstalledFiles.Identity]
    private let description: Data
    private init(attachment: ClusterNativeMemberAttachment, inputs: [DistributedInstalledFiles.Identity], description: Data) {
        self.attachment = attachment; self.inputs = inputs; self.description = description
    }
    static func prepare(validation: DistributedInstalledValidation, deadline: UInt64) throws -> Self? {
        let plan = validation.plan
        guard let attachment = plan.configuration.nativeMember else { return nil }
        try attachment.validate(configuration: plan.configuration, capability: plan.capability)
        let policy = try NativePairMemberPolicy(attachment.policyBytes)
        let wall = Date().timeIntervalSince1970 * 1_000_000_000
        guard wall > 0, wall < Double(policy.notAfter) else {
            throw ClusterConfigurationError.invalid("Saved native coordinator policy has expired")
        }
        var inputs: [DistributedInstalledFiles.Identity] = []
        for (path, hash, executable) in [(plan.localPeer.ownerExecutable, attachment.ownerSHA256, true),
            (attachment.metallib.path, attachment.metallib.sha256, false),
            (attachment.resourceLibrary.path, attachment.resourceLibrary.sha256, false)] {
            inputs.append(try DistributedInstalledFiles.verify(URL(fileURLWithPath: path), expectedSHA256: hash,
                maximumBytes: 256 * 1024 * 1024, executable: executable, deadline: deadline))
        }
        guard let executable = validation.verifiedInputs.first(where: { $0.url.path == plan.localPeer.workerExecutable }) else {
            throw ClusterConfigurationError.invalid("Verified installed native executable is absent")
        }
        try executable.requireUnchanged()
        let raw = try DistributedCapabilityProbe.run(executable: executable.url,
            arguments: ["--describe-protected-runtime", "--config", plan.configurationURL.path,
                "--manifest", plan.manifestURL.path, "--expected-executable-sha256", plan.capability.runtimeBinarySHA256],
            deadline: deadline)
        try validateDescription(raw, attachment: attachment, capability: plan.capability,
            capabilitySHA256: plan.configuration.capabilitySHA256, planSHA256: plan.partition.planSHA256)
        try executable.requireUnchanged(); try validation.requireUnchanged()
        let result = Self(attachment: attachment, inputs: inputs, description: raw)
        try result.requireUnchanged(); try DistributedInstalledFiles.check(deadline)
        return result
    }
    func requireUnchanged() throws { for input in inputs { try input.requireUnchanged() } }

    func readyPolicy(start: ClusterNativeAuthorizationStart, identity: ClusterWorkerIdentity,
                     profile: ClusterWorkerProfile) throws -> ClusterOwnerProtectedReady {
        try requireUnchanged()
        try NativePairMemberPolicy(attachment.policyBytes).require(start)
        return try .init(verifiedDescription: description,
            expectedDescriptionSHA256: attachment.protectedRuntimeDescriptionSHA256,
            start: start, identity: identity, profile: profile)
    }

    // CPU-fixture seam validates actual producer-shaped raw bytes. It does not
    // create the IO-verified installation value or authorize a child.
    static func validateDescription(_ raw: Data, attachment: ClusterNativeMemberAttachment,
                                    capability: ClusterRuntimeCapability, capabilitySHA256: String,
                                    planSHA256: String) throws {
        guard raw.count <= 32 * 1024, raw.last == 10,
              ClusterConfigurationCodec.sha256(raw) == attachment.protectedRuntimeDescriptionSHA256 else {
            throw ClusterConfigurationError.invalid("Protected native description pin or size differs")
        }
        try validateClusterWorkerEnvelope(raw, commandStream: true)
        func flag(_ value: Any?, _ expected: Bool) -> Bool {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue == expected
        }
        guard let o = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              Set(o.keys) == Set(["schema", "staticProfile", "runtimeBinarySHA256", "ordinaryCapabilityBase64",
                "capabilitySHA256", "selectedPlanSHA256", "profileFingerprint", "resourcePolicySHA256", "resourcePolicyBase64",
                "stageCut", "prefillSchedule", "promptTokens", "chunkTokens", "outputTokens", "stopTokenIDs",
                "maximumPlaintextBytes", "maximumFrameBytes", "maximumRecordsPerDirection",
                "maximumCumulativePlaintextBytesPerDirection", "bootstrapProfile", "sourceBindings", "allocationReviews",
                "experimentalExecutionOnly", "wholeProcessPeakProven", "rdmaMeasured", "servingEnabled"]),
              o["schema"] as? String == "qwen9b_protected_runtime_description_v1",
              o["staticProfile"] as? String == attachment.workerProfile,
              o["bootstrapProfile"] as? String == attachment.bootstrapProfile,
              o["runtimeBinarySHA256"] as? String == capability.runtimeBinarySHA256,
              o["capabilitySHA256"] as? String == capabilitySHA256,
              o["selectedPlanSHA256"] as? String == planSHA256,
              o["profileFingerprint"] as? String == capability.profileFingerprint,
              o["resourcePolicySHA256"] as? String == attachment.resourcePolicySHA256,
              o["stageCut"] as? Int == 16, o["prefillSchedule"] as? String == "serial_v1",
              o["promptTokens"] as? Int == 32, o["chunkTokens"] as? Int == 16, o["outputTokens"] as? Int == 2,
              let stops = o["stopTokenIDs"] as? [Int], stops.isEmpty,
              o["maximumPlaintextBytes"] as? Int == 131_072, o["maximumFrameBytes"] as? Int == 131_112,
              o["maximumRecordsPerDirection"] as? Int == 1024,
              o["maximumCumulativePlaintextBytesPerDirection"] as? Int == 16_777_216,
              flag(o["experimentalExecutionOnly"], true),
              flag(o["wholeProcessPeakProven"], false), flag(o["rdmaMeasured"], false),
              flag(o["servingEnabled"], false),
              let source = o["sourceBindings"] as? [String: String], (1...64).contains(source.count),
              source.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 512 && ClusterConfigurationSyntax.hash($0.value) }),
              let reviews = o["allocationReviews"] as? [String], reviews.count == 2, Set(reviews).count == 2,
              reviews.allSatisfy(ClusterConfigurationSyntax.hash) else {
            throw ClusterConfigurationError.invalid("Protected native description changes its closed contract")
        }
        func base64(_ field: String) throws -> Data {
            guard let string = o[field] as? String, let bytes = Data(base64Encoded: string),
                  bytes.base64EncodedString() == string else { throw ClusterConfigurationError.invalid("Protected metadata base64 differs") }
            return bytes
        }
        let ordinary = try base64("ordinaryCapabilityBase64"), resource = try base64("resourcePolicyBase64")
        let policy = try NativePairMemberPolicy(attachment.policyBytes)
        guard try ordinary == ClusterRuntimeCapabilityCodec.encode(capability),
              ClusterConfigurationCodec.sha256(ordinary) == capabilitySHA256,
              ClusterConfigurationCodec.sha256(resource) == attachment.resourcePolicySHA256,
              policy.maximumPlaintext == 131_072, policy.maximumFrame == 131_112,
              policy.maximumRecords == 1024, policy.maximumCumulative == 16_777_216 else {
            throw ClusterConfigurationError.invalid("Protected native capability or resource commitment differs")
        }
    }
}
