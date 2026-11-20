import Foundation

@main struct ResourceProfileCheck {
    static func main() throws {
        let data = try FileHandle.standardInput.read(upToCount: 1_048_577) ?? Data()
        guard sha256(data) == "1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25" else {
            throw ProbeError("Resource fixture raw bytes differ")
        }
        let inputs = try JSONDecoder().decode(QwenDenseProfileFixtureInputs.self, from: data)
        let previous = try checkQwenRegisteredDenseProfiles(inputs)
        var accepted: [String] = [], rejected: [String] = []
        func require(_ label: String, _ value: Bool) throws {
            guard value else { throw ProbeError("Resource fixture failed: " + label) }
            accepted.append(label)
        }
        func reject(_ label: String, _ body: () throws -> Void) throws {
            do { try body() } catch { rejected.append(label); return }
            throw ProbeError("Resource fixture accepted: " + label)
        }
        for specification in QwenDenseRegisteredSpecification.all {
            let input = specification.model == .qwen35NineB ? inputs.nine : inputs.twentySeven
            let profile = try QwenRegisteredDenseModelProfile.admit(configuration: input.configuration,
                manifest: input.manifest, expectedArtifactAggregateSHA256: specification.artifactSHA256,
                canonicalTensors: input.canonicalTensors)
            let selected = try QwenDenseRegisteredResourceProfile(profile: profile)
            let direct = try QwenDenseRegisteredResourceProfile(specification: specification)
            let label = specification.model.rawValue
            try require(label + " exact admitted identity", selected.model == profile.model &&
                selected.configurationSHA256 == profile.configurationSHA256 &&
                selected.manifestSHA256 == profile.manifestSHA256 &&
                selected.artifactAggregateSHA256 == profile.artifactAggregateSHA256 &&
                selected.geometry == profile.geometry &&
                selected.maximumNamedStateBudget == direct.maximumNamedStateBudget)
            try require(label + " metadata cannot authorize execution", !selected.runtimeExecutionAuthorized &&
                !selected.actualPayloadVerificationEstablished && selected.independentResourcePolicyRequired)
            let maximum = try selected.namedStateBudget(maximumTokens: 8320, chunkSize: 512)
            try require(label + " exact maximum", maximum == selected.maximumNamedStateBudget &&
                maximum.conservativeStateAndBoundaryBytes == (profile.model == .qwen35NineB ? 754_188_320 : 1_616_248_896))
            let oldState = try selected.namedStateBudget(maximumTokens: 8193, chunkSize: 512)
            try require(label + " old8193 vector unchanged", oldState.conservativeStateAndBoundaryBytes == specification.namedStateBytes)
            let short = try selected.namedStateBudget(maximumTokens: 5, chunkSize: 2)
            try require(label + " short request uses own geometry", short.attentionLayers == specification.layers / 4 &&
                short.recurrentLayers == specification.layers * 3 / 4 && short.maximumTokens == 5)
            for tokens in [0, -1, 8321, Int.max] {
                try reject(label + " context " + String(tokens)) { _ = try selected.namedStateBudget(maximumTokens: tokens, chunkSize: 1) }
            }
            for chunk in [0, -1, 513, Int.max] {
                try reject(label + " chunk " + String(chunk)) { _ = try selected.namedStateBudget(maximumTokens: 8320, chunkSize: chunk) }
            }
            try reject(label + " chunk exceeds context") { _ = try selected.namedStateBudget(maximumTokens: 1, chunkSize: 2) }
            if profile.model == .qwen35NineB {
                let old = try QwenRegistered9BLongPrefillAdmission.admit(configuration: input.configuration,
                    expectedArtifactAggregateSHA256: specification.artifactSHA256,
                    promptCount: 8192, chunkSize: 512, outputCount: 1, batchSize: 1,
                    teacherTokenCount: 0, nativeDType: "bfloat16", bf16ConversionEnabled: true)
                try require("9B exact old receipt budget and limits", old.budget == oldState &&
                    selected.namedTensorByteCeiling == old.namedTensorByteCeiling &&
                    selected.namedTensorByteCeiling == 805_306_368 &&
                    selected.maximumManifestPayloadBytes == 8_589_934_592)
            } else {
                try require("27B distinct bounded metadata limits", selected.maximumManifestPayloadBytes == 16_320_415_757 &&
                    selected.maximumManifestPayloadBytes == profile.manifestPayloadBytes &&
                    selected.namedTensorByteCeiling == 1_616_248_896 &&
                    selected.namedTensorByteCeiling > QwenRegistered9BLongPrefillAdmission.namedTensorByteCeiling)
                try require("27B planning-only default unchanged", try profile.makePlanningPlan().stages.map(\.sourceRange) == [0..<32, 32..<64])
                for cut in [4, 8, 12, 16, 28, 36, 60] {
                    try reject("27B non-default planning cut " + String(cut)) { _ = try profile.makePlanningPlan(stageCut: cut) }
                }
                try reject("27B does not become old9B long admission") {
                    _ = try QwenRegistered9BLongPrefillAdmission.admit(configuration: input.configuration,
                        expectedArtifactAggregateSHA256: specification.artifactSHA256,
                        promptCount: 8192, chunkSize: 512, outputCount: 1, batchSize: 1,
                        teacherTokenCount: 0, nativeDType: "bfloat16", bf16ConversionEnabled: true)
                }
            }
        }
        let result: [String: Any] = ["schema": "registered_dense_resource_profile_check_v1",
            "existingAccepted": previous.acceptedChecks, "existingRejected": previous.rejectedChecks,
            "accepted": accepted, "rejected": rejected, "acceptedCount": accepted.count,
            "rejectedCount": rejected.count, "metadataOnly": true, "nativeExecuted": false]
        var encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        encoded.append(10)
        try FileHandle.standardOutput.write(contentsOf: encoded)
    }
}
