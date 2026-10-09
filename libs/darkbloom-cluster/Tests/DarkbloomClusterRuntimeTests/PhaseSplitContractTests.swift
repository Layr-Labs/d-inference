import DarkbloomClusterProtocol
import Foundation
import Testing
@_spi(Benchmark) @testable import DarkbloomClusterRuntime

// Phase split (pair prefill, single-rank decode): the agreement terms, the
// hand-off wire format and its verification, the relay of tokens selected
// alone, and the mode declaration. Pure contracts on the registered
// configuration: no collective, model, GPU or network. The state bytes are
// synthetic; the manifest they follow is checked against sizes a real run of
// each registered model recorded. Every fixture takes its geometry, profile
// and Plan from the registered model it names: nothing here is a 9B constant
// that the 27B borrows.

private enum PhaseSplitFixture {
    static func configuration(_ model: QwenRegisteredDenseModel = .qwen35NineB) throws -> Data {
        // Tests/DarkbloomClusterRuntimeTests -> libs, then the worker's fixtures.
        let libraries = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let name = model == .qwen35NineB ? "qwen35-9b" : "qwen38-27b"
        return try Data(contentsOf: libraries.appendingPathComponent(
            "darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-\(name).configuration.json"))
    }

    static func specification(_ model: QwenRegisteredDenseModel = .qwen35NineB) throws -> QwenDenseRegisteredSpecification {
        try QwenResidentModelDefinition(model: model).specification
    }

    static func plan(cut: Int, model: QwenRegisteredDenseModel = .qwen35NineB) throws -> QwenLayerStagePlan {
        try QwenLayerStagePlan(configuration: try configuration(model),
            ranges: [0..<cut, cut..<(try specification(model).layers)])
    }

    static func request(promptCount: Int = 24, chunkSize: Int = 16, outputCount: Int = 8,
                        stopTokenIDs: Set<Int> = [], id: UUID = UUID(),
                        model: QwenRegisteredDenseModel = .qwen35NineB) throws -> QwenLayerStageGenerationRequest {
        try QwenLayerStageGenerationRequest(
            profile: try QwenResidentAdapterDefinition.profile(specification: try specification(model)), requestID: id,
            promptTokenIDs: (0..<promptCount).map { 1000 + $0 }, chunkSize: chunkSize, outputCount: outputCount,
            stopTokenIDs: stopTokenIDs)
    }

    static func agreement(_ request: QwenLayerStageGenerationRequest, cut: Int = 4, split: Bool = true,
                          maximumSegmentBytes: Int = 16 * 1024 * 1024, relayBatchTokens: Int = 16,
                          epoch: UUID = UUID(uuidString: "6f0c7a54-11d2-4c1e-9a44-0d5a6a5f0b11")!,
                          model: QwenRegisteredDenseModel = .qwen35NineB) throws -> QwenLayerStageGenerationAgreement {
        let plan = try plan(cut: cut, model: model)
        let source = try QwenLayerStageWireSourceIdentity(
            sourceConfigurationSHA256: sha256(try configuration(model)),
            artifactAggregateSHA256: try specification(model).artifactSHA256,
            storageCommitmentSHA256: String(repeating: "c", count: 64),
            planFingerprint: plan.fingerprint, producerStageFingerprint: plan.stages[0].fingerprint)
        return try QwenLayerStageGenerationAgreement(request: request, membershipEpoch: epoch, source: source,
            consumerStageFingerprint: plan.stages[1].fingerprint,
            rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "1", count: 64)],
            numericalPolicySHA256: String(repeating: "3", count: 64),
            phaseSplit: split ? try QwenPhaseSplitPlan(plan: plan, geometry: try specification(model).expectedGeometry(),
                request: request, maximumSegmentBytes: maximumSegmentBytes, relayBatchTokens: relayBatchTokens) : nil)
    }

    /// Deterministic bytes that differ from one position to the next.
    static func bytes(_ count: Int, seed: UInt64) -> Data {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            for index in 0..<count {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                raw[index] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return data
    }

    /// A producer state that follows the agreed manifest, as rank 0's session would export it.
    static func components(_ split: QwenPhaseSplitPlan) -> [QwenPhaseSplitHandoffSender.Component] {
        split.shapes.enumerated().map { index, shape in
            if shape.component == QwenPhaseSplitStateShape.positionOffsets {
                return .init(shape: shape, sha256: QwenPhaseSplitHandoffHeader.positionOffsetsSHA256(
                    committedTokens: split.terms.handoffCommittedTokens), bytes: nil)
            }
            let data = bytes(shape.byteCount, seed: UInt64(index + 1))
            return .init(shape: shape, sha256: sha256(data), bytes: data)
        }
    }

    /// A control state machine advanced to the hand-off point: every prompt
    /// frame committed, the first token agreed, its decision `proceed`.
    static func controlAtHandoff(_ agreement: QwenLayerStageGenerationAgreement, firstToken: Int = 41) throws -> QwenLayerStageGenerationControl {
        let control = QwenLayerStageGenerationControl(agreement: agreement)
        while control.phase == .frame {
            let expected = try control.beginFrame()
            let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected,
                payloadSHA256: sha256(Data("prompt-\(expected.frame.sequence)".utf8)))
            let committed = expected.frame.tokenOffset + expected.frame.tokenCount
            try control.acknowledgeFrame(rank: 0, packet: packet, nativeCommittedTokens: committed)
            try control.acknowledgeFrame(rank: 1, packet: packet, nativeCommittedTokens: committed)
            guard control.phase == .token else { continue }
            let token = try QwenLayerStageGenerationTokenPacket(agreement: agreement, boundaryFingerprint: packet.fingerprint,
                previousTokenChainSHA256: control.tokenChainSHA256, ordinal: 0,
                committedTokens: control.committedTokens, tokenID: firstToken)
            try control.acknowledgeToken(rank: 1, packet: token); try control.acknowledgeToken(rank: 0, packet: token)
            _ = try control.takeCommittedToken()
            let decision = try control.decide(continueRequested: true)
            try control.acknowledgeDecision(rank: 0, packet: decision); try control.acknowledgeDecision(rank: 1, packet: decision)
            break
        }
        return control
    }
}

@Suite("Phase split contracts (registered configuration, no execution)")
struct PhaseSplitContractTests {
    @Test func modeIsDeclaredNeverGuessed() throws {
        // One closed list, shared with the worker's flag and the capability record.
        #expect(QwenResidentGenerationMode.allCases.map(\.rawValue) == ["pipeline_v1", "pipeline_compact_decode_v1", "phase_split_v1"])
        #expect(ClusterGenerationMode(rawValue: "phase_split_v1") == QwenResidentGenerationMode.phaseSplit)
        // A misspelt or empty declaration is no mode at all; nothing maps it to the default.
        for bad in ["phase-split", "", "phase_split", "PHASE_SPLIT_V1", "pipeline"] { #expect(ClusterGenerationMode(rawValue: bad) == nil) }
        // The runtime reads no environment for the mode. The name a launcher
        // used before the worker had its argument is refused, never obeyed,
        // whether or not qualification switches are permitted.
        for switches in [QwenResidentQualificationSwitches.refused, .permittedByExplicitFlag] {
            #expect(throws: ProbeError.self) {
                try switches.admit(environment: ["DARKBLOOM_CLUSTER_GENERATION_MODE": "phase_split_v1"])
            }
        }
        // The pipeline adds nothing to the load agreement; another mode is bound into it.
        #expect(QwenResidentGenerationMode.pipeline.loadAgreementFields.isEmpty)
        #expect(QwenResidentGenerationMode.phaseSplit.loadAgreementFields == ["qwen-resident-generation-mode-v1", "phase_split_v1"])
        #expect(QwenResidentGenerationMode.pipelineCompactDecode.loadAgreementFields.last == "pipeline_compact_decode_v1")
        // The qualification socket is declared the same way and never guessed either.
        #expect(try ClusterTransport.admit(environment: [:]) == .jaccl)
        #expect(try ClusterTransport.admit(environment: ["DARKBLOOM_CLUSTER_TRANSPORT": "local-socket-test"]) == .localSocketTest)
        #expect(throws: ProbeError.self) { _ = try ClusterTransport.admit(environment: ["DARKBLOOM_CLUSTER_TRANSPORT": "jaccl"]) }
        #expect(throws: ProbeError.self) { _ = try ClusterTransport.admit(environment: ["DARKBLOOM_CLUSTER_TRANSPORT": "tcp"]) }
        #expect(ClusterTransport.jaccl.loadAgreementFields.isEmpty)
        #expect(ClusterTransport.localSocketTest.loadAgreementFields == ["qwen-resident-transport-v1", "local-socket-test"])
        // A fault is a qualification input with a closed spelling.
        #expect(try QwenPhaseSplitFault.admit(environment: [:]) == nil)
        #expect(try QwenPhaseSplitFault.admit(environment: ["DARKBLOOM_CLUSTER_QUALIFICATION_FAULT": "handoff_corrupt_segment=3"])
            == QwenPhaseSplitFault(corruptSegment: 3))
        #expect(try QwenPhaseSplitFault.admit(environment: ["DARKBLOOM_CLUSTER_QUALIFICATION_FAULT": "handoff_stall_after_segment=2:1500"])
            == QwenPhaseSplitFault(stallAfterSegment: 2, stallMilliseconds: 1500))
        for bad in ["handoff_corrupt_segment", "handoff_corrupt_segment=-1", "handoff_stall_after_segment=2", "exit=1", "handoff_corrupt_segment=03"] {
            #expect(throws: ProbeError.self) { _ = try QwenPhaseSplitFault.admit(environment: ["DARKBLOOM_CLUSTER_QUALIFICATION_FAULT": bad]) }
        }
    }

    @Test func qualificationSwitchesAreRefusedUnlessExplicitlyPermitted() throws {
        let serving = ["JACCL_RANK": "0", "JACCL_COORDINATOR": "10.0.0.1:47000", "MLX_ENABLE_TF32": "1"]
        // What an installed caller passes, and what `load` defaults to.
        let refused = QwenResidentQualificationSwitches.refused, permitted = QwenResidentQualificationSwitches.permittedByExplicitFlag
        #expect(!refused.permitted && permitted.permitted)
        try refused.admit(environment: serving); try permitted.admit(environment: serving)
        for (name, value) in [("DARKBLOOM_CLUSTER_TRANSPORT", "local-socket-test"), ("DARKBLOOM_CLUSTER_TRANSPORT", ""),
                              ("DARKBLOOM_CLUSTER_QUALIFICATION_FAULT", "handoff_corrupt_segment=3"),
                              ("DARKBLOOM_CLUSTER_QUALIFICATION_FAULT", "anything")] {
            var environment = serving; environment[name] = value
            // Present is enough: the switch is refused by name, not parsed, not ignored.
            do {
                try refused.admit(environment: environment)
                Issue.record("\(name) was not refused")
            } catch {
                #expect("\(error)".contains(name) && "\(error)".contains("--qualification-switches"))
            }
            try permitted.admit(environment: environment)
        }
        // The names are the ones the transport and the fault are read from.
        #expect(QwenResidentQualificationSwitches.transportEnvironmentName == CollectiveLocalSocket.environmentName)
        #expect(QwenResidentQualificationSwitches.faultEnvironmentName == QwenPhaseSplitFault.environmentName)
    }

    @Test func everyRegisteredModelListsItsOwnGenerationModes() throws {
        for model in QwenRegisteredDenseModel.allCases {
            let definition = try QwenResidentModelDefinition(model: model)
            // The pipeline first; the row is what load, the worker and the capability consult.
            #expect(definition.supportedGenerationModes == [.pipeline, .pipelineCompactDecode, .phaseSplit])
            #expect(QwenResidentCapabilityMetadata.registeredModel(runtimeModelID: model.rawValue)?.supportedGenerationModes
                == definition.supportedGenerationModes)
        }
        #expect(QwenResidentCapabilityMetadata.registeredModel(runtimeModelID: "registered_qwen4")?.supportedGenerationModes == nil)
    }

    @Test func compactDecodeIsADeclaredFraming() throws {
        let request = try PhaseSplitFixture.request()
        let plan = try PhaseSplitFixture.plan(cut: 4)
        func agreement(compact: Bool) throws -> QwenLayerStageGenerationAgreement {
            try QwenLayerStageGenerationAgreement(request: request,
                membershipEpoch: UUID(uuidString: "6f0c7a54-11d2-4c1e-9a44-0d5a6a5f0b11")!,
                source: try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating: "a", count: 64),
                    artifactAggregateSHA256: String(repeating: "b", count: 64),
                    storageCommitmentSHA256: String(repeating: "c", count: 64), planFingerprint: plan.fingerprint,
                    producerStageFingerprint: plan.stages[0].fingerprint),
                consumerStageFingerprint: plan.stages[1].fingerprint,
                rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "1", count: 64)],
                numericalPolicySHA256: String(repeating: "3", count: 64), compactDecode: compact)
        }
        let plain = try agreement(compact: false), compact = try agreement(compact: true)
        // A rank that frames decode steps differently holds another fingerprint.
        #expect(plain.fingerprint != compact.fingerprint)
        #expect(!String(decoding: try canonicalJSONData(plain.descriptor), as: UTF8.self).contains("decodeFraming"))
        #expect(String(decoding: try canonicalJSONData(compact.descriptor), as: UTF8.self).contains("\"decodeFraming\":\"combined_frames_v1\""))
    }

    @Test func manifestEqualsTheStateARealRunRecorded() throws {
        // The registered model's state after 8,319 committed tokens, as the
        // single-Mac reference recorded it (72 entries, 324,108,320 bytes):
        // rank 0's share at each cut, by entry count and logical bytes.
        let geometry = try PhaseSplitFixture.specification().expectedGeometry()
        let measured = [4: (9, 40_513_540), 8: (18, 81_027_080), 12: (27, 121_540_620), 16: (36, 162_054_160)]
        for (cut, expected) in measured {
            let shapes = try QwenPhaseSplitPlan.expectedShapes(stage: try PhaseSplitFixture.plan(cut: cut).stages[0],
                geometry: geometry, committedTokens: 8319, activationDType: "bfloat16")
            #expect(shapes.count == expected.0)
            #expect(shapes.map(\.byteCount).reduce(0, +) == expected.1)
        }
        let shapes = try QwenPhaseSplitPlan.expectedShapes(stage: try PhaseSplitFixture.plan(cut: 4).stages[0],
            geometry: geometry, committedTokens: 8319, activationDType: "bfloat16")
        // Snapshot order: by layer, then by component name.
        #expect(shapes.map { "\($0.globalLayerIndex)|\($0.component)" } == [
            "0|conv", "0|ssm", "1|conv", "1|ssm", "2|conv", "2|ssm", "3|kv.keys", "3|kv.position_offsets", "3|kv.values"])
        #expect(shapes[0].shape == [1, 3, 8192] && shapes[0].dtype == "bfloat16" && shapes[0].byteCount == 49_152)
        #expect(shapes[1].shape == [1, 32, 128, 128] && shapes[1].dtype == "float32" && shapes[1].byteCount == 2_097_152)
        #expect(shapes[6].shape == [1, 4, 8319, 256] && shapes[6].byteCount == 17_037_312)
        #expect(shapes[7].shape == [1] && shapes[7].dtype == "int32" && shapes[7].byteCount == 4)
    }

    @Test func largestAdmittedPromptNeedsNoCut() throws {
        // After 8,192 prompt tokens an attention tensor is exactly the
        // point-to-point limit, so every component is one transfer.
        let request = try PhaseSplitFixture.request(promptCount: 8192, chunkSize: 512, outputCount: 128)
        let split = try #require(try PhaseSplitFixture.agreement(request, cut: 8).phaseSplit)
        #expect(split.shapes.map(\.byteCount).max() == CollectivePointToPointShape.hardByteLimit)
        #expect(split.terms.entryCount == 18 && split.terms.handoffCommittedTokens == 8192)
        #expect(split.terms.logicalBytes == 6 * (49_152 + 2_097_152) + 2 * (2 * 16_777_216 + 4))
        // Position offsets are not sent: 18 entries, 2 of them offsets.
        #expect(split.segments.count == 16 && split.terms.segmentCount == 16)
        #expect(split.segments.allSatisfy { $0.tokens == nil && $0.byteCount <= CollectivePointToPointShape.hardByteLimit })
    }

    @Test func onlyAttentionTensorsAreCutAndOnlyAlongTokens() throws {
        let request = try PhaseSplitFixture.request(promptCount: 2048, chunkSize: 512, outputCount: 8)
        // 2 MiB per segment: an attention tensor of 2,048 tokens is 4 MiB.
        let split = try #require(try PhaseSplitFixture.agreement(request, maximumSegmentBytes: 2_097_152).phaseSplit)
        let keys = split.segments.filter { split.shapes[$0.entryIndex].component == "kv.keys" }
        #expect(keys.map(\.tokens) == [Optional(0..<1024), Optional(1024..<2048)])
        #expect(keys.allSatisfy { $0.shape == [1, 4, 1024, 256] && $0.byteCount == 2_097_152 })
        #expect(split.segments.filter { $0.tokens == nil }.count == 6)
        #expect(split.segments.map(\.byteCount).reduce(0, +) == split.terms.logicalBytes - 4)
        // A recurrent tensor is never cut: a limit below its size is refused.
        #expect(throws: ProbeError.self) { _ = try PhaseSplitFixture.agreement(request, maximumSegmentBytes: 1_048_576) }
        #expect(throws: ProbeError.self) { _ = try PhaseSplitFixture.agreement(request, maximumSegmentBytes: 16 * 1024 * 1024 + 1) }
    }

    @Test func termsAreFencedByTheAgreement() throws {
        let request = try PhaseSplitFixture.request()
        let pipeline = try PhaseSplitFixture.agreement(request, split: false)
        let split = try PhaseSplitFixture.agreement(request)
        // The pipeline's agreement bytes do not mention phase split at all.
        #expect(!String(decoding: try canonicalJSONData(pipeline.descriptor), as: UTF8.self).contains("phaseSplit"))
        #expect(String(decoding: try canonicalJSONData(split.descriptor), as: UTF8.self).contains("qwen_stage_phase_split_v1"))
        // A rank that derives any other mode, cut, batch size or segment limit
        // holds another fingerprint and stops at the readiness exchange.
        var fingerprints = Set([pipeline.fingerprint, split.fingerprint])
        fingerprints.insert(try PhaseSplitFixture.agreement(request, cut: 8).fingerprint)
        fingerprints.insert(try PhaseSplitFixture.agreement(request, relayBatchTokens: 8).fingerprint)
        fingerprints.insert(try PhaseSplitFixture.agreement(request, maximumSegmentBytes: 8 * 1024 * 1024).fingerprint)
        #expect(fingerprints.count == 5)
        #expect(try PhaseSplitFixture.agreement(request).fingerprint == split.fingerprint)
        // Terms derived for another prompt cannot be attached to this request.
        let other = try #require(try PhaseSplitFixture.agreement(try PhaseSplitFixture.request(promptCount: 25)).phaseSplit)
        let plan = try PhaseSplitFixture.plan(cut: 4)
        #expect(throws: ProbeError.self) {
            _ = try QwenLayerStageGenerationAgreement(request: request, membershipEpoch: UUID(),
                source: try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating: "a", count: 64),
                    artifactAggregateSHA256: String(repeating: "b", count: 64),
                    storageCommitmentSHA256: String(repeating: "c", count: 64), planFingerprint: plan.fingerprint,
                    producerStageFingerprint: plan.stages[0].fingerprint),
                consumerStageFingerprint: plan.stages[1].fingerprint,
                rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
                numericalPolicySHA256: String(repeating: "3", count: 64), phaseSplit: other)
        }
    }

    @Test func controlFrameIsFixedSizeAndZeroPadded() throws {
        let body = Data(#"{"a":1}"#.utf8)
        let frame = try QwenControlFrame.encode(body, frameBytes: 64)
        #expect(frame.count == 64 && Array(frame.prefix(4)) == [0, 0, 0, 7])
        #expect(Array(frame.suffix(64 - 11)) == [UInt8](repeating: 0, count: 53))
        #expect(try QwenControlFrame.decode(frame, frameBytes: 64) == body)
        // Stale bytes after the body, a wrong size and an impossible length are faults.
        var stale = frame; stale[40] = 1
        #expect(throws: ProbeError.self) { _ = try QwenControlFrame.decode(stale, frameBytes: 64) }
        #expect(throws: ProbeError.self) { _ = try QwenControlFrame.decode(frame.dropLast(), frameBytes: 64) }
        var long = frame; long[3] = 61
        #expect(throws: ProbeError.self) { _ = try QwenControlFrame.decode(long, frameBytes: 64) }
        var empty = frame; empty[3] = 0
        #expect(throws: ProbeError.self) { _ = try QwenControlFrame.decode(empty, frameBytes: 64) }
        #expect(throws: ProbeError.self) { _ = try QwenControlFrame.encode(Data(count: 61), frameBytes: 64) }
        #expect(throws: ProbeError.self) { _ = try QwenControlFrame.encode(Data(), frameBytes: 64) }
    }

    @Test func slabsReassembleToTheSameBytes() throws {
        let shape = QwenPhaseSplitStateShape(globalLayerIndex: 3, component: "kv.keys", shape: [1, 3, 7, 5],
                                             dtype: "bfloat16", byteCount: 3 * 7 * 5 * 2)
        let original = PhaseSplitFixture.bytes(shape.byteCount, seed: 9)
        var rebuilt = Data(count: shape.byteCount)
        for tokens in [0..<3, 3..<4, 4..<7] {
            let slab = try QwenPhaseSplitSlab.extract(original, shape: shape, tokens: tokens)
            #expect(slab.count == 3 * tokens.count * 10)
            // Head by head: the slab's second head starts at that head's first selected token.
            #expect(slab[slab.startIndex + tokens.count * 10] == original[original.startIndex + (7 + tokens.lowerBound) * 10])
            try QwenPhaseSplitSlab.place(slab, into: &rebuilt, shape: shape, tokens: tokens)
        }
        #expect(rebuilt == original)
        #expect(throws: ProbeError.self) { _ = try QwenPhaseSplitSlab.extract(original, shape: shape, tokens: 5..<8) }
        #expect(throws: ProbeError.self) { _ = try QwenPhaseSplitSlab.extract(original.dropLast(), shape: shape, tokens: 0..<1) }
    }

    @Test func verifiedHandoffDeliversEveryComponent() throws {
        for limit in [16 * 1024 * 1024, 2_097_152] {
            let request = try PhaseSplitFixture.request(promptCount: 2048, chunkSize: 512, outputCount: 8)
            let agreement = try PhaseSplitFixture.agreement(request, cut: 8, maximumSegmentBytes: limit)
            let split = try #require(agreement.phaseSplit)
            let components = PhaseSplitFixture.components(split)
            let sender = try QwenPhaseSplitHandoffSender(agreement: agreement,
                tokenChainSHA256: agreement.initialTokenChainSHA256, components: components)
            #expect(sender.header.content.stateSHA256 == QwenPhaseSplitHandoffHeader.stateSHA256(
                sender.header.content.entries, committedTokens: 2048))
            // The header crosses as one fixed frame.
            let frame = try QwenControlFrame.encode(try sender.header.encoded(), frameBytes: QwenPhaseSplitHandoffHeader.frameBytes)
            let receiver = try QwenPhaseSplitHandoffReceiver(agreement: agreement, tokenChainSHA256: agreement.initialTokenChainSHA256)
            try receiver.acceptHeader(try QwenControlFrame.decode(frame, frameBytes: QwenPhaseSplitHandoffHeader.frameBytes))
            #expect(receiver.header?.fingerprint == sender.header.fingerprint)
            for (index, segment) in sender.segments.enumerated() {
                try receiver.acceptSegment(index, bytes: try sender.bytes(for: segment))
            }
            let verified = try receiver.finish()
            #expect(receiver.complete && receiver.refusal == nil && verified.count == 16)
            for (index, component) in components.enumerated() { #expect(verified[index] == component.bytes) }
        }
    }

    @Test func corruptedSegmentIsRefusedAfterTheTransferCompletes() throws {
        let request = try PhaseSplitFixture.request()
        let agreement = try PhaseSplitFixture.agreement(request)
        let sender = try QwenPhaseSplitHandoffSender(agreement: agreement, tokenChainSHA256: agreement.initialTokenChainSHA256,
            components: PhaseSplitFixture.components(try #require(agreement.phaseSplit)))
        for corrupted in [0, 3, sender.segments.count - 1] {
            let receiver = try QwenPhaseSplitHandoffReceiver(agreement: agreement, tokenChainSHA256: agreement.initialTokenChainSHA256)
            try receiver.acceptHeader(try sender.header.encoded())
            for (index, segment) in sender.segments.enumerated() {
                var bytes = try sender.bytes(for: segment)
                if index == corrupted { bytes[bytes.startIndex + bytes.count / 2] ^= 0x10 }
                // Still accepted: the sender is mid-transfer and must not be left blocked.
                try receiver.acceptSegment(index, bytes: bytes)
            }
            // Nothing is judged until every agreed segment has arrived.
            #expect(receiver.complete && receiver.refusal == nil)
            let shape = try #require(agreement.phaseSplit).shapes[sender.segments[corrupted].entryIndex]
            do {
                _ = try receiver.finish()
                Issue.record("a corrupted hand-off segment was accepted")
            } catch {
                // The refusal names the component whose bytes differ.
                #expect("\(error)".contains("global layer \(shape.globalLayerIndex) \(shape.component)"))
            }
            // A refused hand-off stays refused.
            #expect(receiver.refusal != nil)
            #expect(throws: ProbeError.self) { _ = try receiver.finish() }
        }
        // A corrupted slab of a cut tensor is caught on the reassembled tensor.
        let long = try PhaseSplitFixture.request(promptCount: 2048, chunkSize: 512, outputCount: 8)
        let cutAgreement = try PhaseSplitFixture.agreement(long, maximumSegmentBytes: 2_097_152)
        let cutSender = try QwenPhaseSplitHandoffSender(agreement: cutAgreement, tokenChainSHA256: cutAgreement.initialTokenChainSHA256,
            components: PhaseSplitFixture.components(try #require(cutAgreement.phaseSplit)))
        let slab = try #require(cutSender.segments.firstIndex(where: { $0.tokens == Optional(0..<1024) }))
        let receiver = try QwenPhaseSplitHandoffReceiver(agreement: cutAgreement, tokenChainSHA256: cutAgreement.initialTokenChainSHA256)
        try receiver.acceptHeader(try cutSender.header.encoded())
        for (index, segment) in cutSender.segments.enumerated() {
            var bytes = try cutSender.bytes(for: segment)
            if index == slab { bytes[bytes.startIndex] ^= 1 }
            try receiver.acceptSegment(index, bytes: bytes)
        }
        #expect(throws: ProbeError.self) { _ = try receiver.finish() }
    }

    @Test func headerMustEqualTheLocalExpectation() throws {
        let request = try PhaseSplitFixture.request()
        let agreement = try PhaseSplitFixture.agreement(request)
        let split = try #require(agreement.phaseSplit)
        let chain = agreement.initialTokenChainSHA256
        let sender = try QwenPhaseSplitHandoffSender(agreement: agreement, tokenChainSHA256: chain,
            components: PhaseSplitFixture.components(split))
        let header = try sender.header.encoded()
        func refused(_ data: Data, agreement other: QwenLayerStageGenerationAgreement? = nil, chain otherChain: String? = nil) throws {
            let receiver = try QwenPhaseSplitHandoffReceiver(agreement: other ?? agreement, tokenChainSHA256: otherChain ?? chain)
            #expect(throws: ProbeError.self) { try receiver.acceptHeader(data) }
            #expect(receiver.header == nil && receiver.refusal != nil)
            // Nothing may follow a refused header.
            #expect(throws: ProbeError.self) { try receiver.acceptSegment(0, bytes: Data(count: 1)) }
            #expect(throws: ProbeError.self) { _ = try receiver.finish() }
        }
        // Another request, cut, epoch or selected history.
        try refused(header, agreement: try PhaseSplitFixture.agreement(try PhaseSplitFixture.request(stopTokenIDs: [7], id: request.requestID)))
        try refused(header, agreement: try PhaseSplitFixture.agreement(request, cut: 8))
        try refused(header, agreement: try PhaseSplitFixture.agreement(request, epoch: UUID()))
        try refused(header, chain: String(repeating: "9", count: 64))
        // Any stated field that differs from what this rank derives itself.
        func edited(_ from: String, _ to: String) throws -> Data {
            let text = String(decoding: header, as: UTF8.self)
            #expect(text.contains(from))
            return Data(text.replacingOccurrences(of: from, with: to).utf8)
        }
        try refused(try edited("\"committedTokens\":24", "\"committedTokens\":25"))
        try refused(try edited("\"selectedTokenCount\":1", "\"selectedTokenCount\":2"))
        try refused(try edited("\"byteCount\":2097152", "\"byteCount\":2097153"))
        try refused(try edited("[1,32,128,128]", "[1,32,128,129]"))
        try refused(try edited("\"component\":\"ssm\"", "\"component\":\"ssn\""))
        try refused(try edited(sender.header.content.stateSHA256, String(repeating: "0", count: 64)))
        // Position offsets are fixed by the frontier; another digest for them is refused.
        try refused(try edited(QwenPhaseSplitHandoffHeader.positionOffsetsSHA256(committedTokens: 24),
                               QwenPhaseSplitHandoffHeader.positionOffsetsSHA256(committedTokens: 25)))
        try refused(Data("{}".utf8))
        // The sender refuses its own state when it is not the agreed manifest.
        var components = PhaseSplitFixture.components(split)
        components.swapAt(0, 2)
        #expect(throws: ProbeError.self) { _ = try QwenPhaseSplitHandoffSender(agreement: agreement, tokenChainSHA256: chain, components: components) }
        components = PhaseSplitFixture.components(split)
        let wrong = QwenPhaseSplitStateShape(globalLayerIndex: 0, component: "conv", shape: [1, 3, 8191], dtype: "bfloat16", byteCount: 49_146)
        components[0] = .init(shape: wrong, sha256: components[0].sha256, bytes: Data(count: 49_146))
        #expect(throws: ProbeError.self) { _ = try QwenPhaseSplitHandoffSender(agreement: agreement, tokenChainSHA256: chain, components: components) }
        components = PhaseSplitFixture.components(split)
        components[1] = .init(shape: components[1].shape, sha256: components[1].sha256, bytes: components[1].bytes?.dropLast())
        #expect(throws: ProbeError.self) { _ = try QwenPhaseSplitHandoffSender(agreement: agreement, tokenChainSHA256: chain, components: components) }
        components = PhaseSplitFixture.components(split)
        components[1] = .init(shape: components[1].shape, sha256: components[1].sha256, bytes: nil)
        #expect(throws: ProbeError.self) { _ = try QwenPhaseSplitHandoffSender(agreement: agreement, tokenChainSHA256: chain, components: components) }
        // A sender that states a digest its bytes do not have is caught by the receiver, not trusted.
        components = PhaseSplitFixture.components(split)
        components[1] = .init(shape: components[1].shape, sha256: String(repeating: "0", count: 64), bytes: components[1].bytes)
        let lying = try QwenPhaseSplitHandoffSender(agreement: agreement, tokenChainSHA256: chain, components: components)
        let cautious = try QwenPhaseSplitHandoffReceiver(agreement: agreement, tokenChainSHA256: chain)
        try cautious.acceptHeader(try lying.header.encoded())
        for (index, segment) in lying.segments.enumerated() { try cautious.acceptSegment(index, bytes: try lying.bytes(for: segment)) }
        #expect(throws: ProbeError.self) { _ = try cautious.finish() }
        // A pipeline agreement has no hand-off at all.
        let pipeline = try PhaseSplitFixture.agreement(request, split: false)
        #expect(throws: ProbeError.self) { _ = try QwenPhaseSplitHandoffReceiver(agreement: pipeline, tokenChainSHA256: chain) }
        #expect(throws: ProbeError.self) { _ = try QwenPhaseSplitHandoffSender(agreement: pipeline, tokenChainSHA256: chain, components: components) }
    }

    @Test func segmentsArriveInOrderAndCompletely() throws {
        let request = try PhaseSplitFixture.request()
        let agreement = try PhaseSplitFixture.agreement(request)
        let chain = agreement.initialTokenChainSHA256
        let sender = try QwenPhaseSplitHandoffSender(agreement: agreement, tokenChainSHA256: chain,
            components: PhaseSplitFixture.components(try #require(agreement.phaseSplit)))
        let early = try QwenPhaseSplitHandoffReceiver(agreement: agreement, tokenChainSHA256: chain)
        #expect(throws: ProbeError.self) { try early.acceptSegment(0, bytes: try sender.bytes(for: sender.segments[0])) }
        let receiver = try QwenPhaseSplitHandoffReceiver(agreement: agreement, tokenChainSHA256: chain)
        try receiver.acceptHeader(try sender.header.encoded())
        #expect(throws: ProbeError.self) { try receiver.acceptHeader(try sender.header.encoded()) }
        #expect(throws: ProbeError.self) { try receiver.acceptSegment(1, bytes: try sender.bytes(for: sender.segments[1])) }
        #expect(throws: ProbeError.self) { try receiver.acceptSegment(0, bytes: try sender.bytes(for: sender.segments[0]).dropLast()) }
        try receiver.acceptSegment(0, bytes: try sender.bytes(for: sender.segments[0]))
        #expect(throws: ProbeError.self) { try receiver.acceptSegment(0, bytes: try sender.bytes(for: sender.segments[0])) }
        // Ending early is not acceptance.
        #expect(!receiver.complete)
        #expect(throws: ProbeError.self) { _ = try receiver.finish() }
    }

    @Test func relayedTokensGiveBothRanksOneHistory() throws {
        let request = try PhaseSplitFixture.request(outputCount: 6, stopTokenIDs: [99])
        let agreement = try PhaseSplitFixture.agreement(request, relayBatchTokens: 4)
        let owner = try PhaseSplitFixture.controlAtHandoff(agreement), adopter = try PhaseSplitFixture.controlAtHandoff(agreement)
        #expect(owner.phase == .frame && owner.selectedTokenCount == 1 && owner.committedTokens == 24)
        #expect(owner.tokenChainSHA256 == adopter.tokenChainSHA256)
        let handoff = String(repeating: "7", count: 64)
        func digest(_ ordinal: Int) -> String { sha256(Data("residual-\(ordinal)".utf8)) }

        // Rank 1 selected three tokens alone; the last is a stop token.
        let relay = try QwenPhaseSplitRelayPacket(agreement: agreement, handoffFingerprint: handoff, firstOrdinal: 1,
            previousTokenChainSHA256: adopter.tokenChainSHA256, tokenIDs: [50, 51, 99], payloadSHA256: (1...3).map(digest))
        let frame = try QwenControlFrame.encode(try relay.encoded(), frameBytes: QwenPhaseSplitRelayPacket.frameBytes)
        // Rank 0 reads it against its own count and history, publishes, answers.
        let received = try QwenPhaseSplitRelayPacket.decode(try QwenControlFrame.decode(frame, frameBytes: QwenPhaseSplitRelayPacket.frameBytes),
            agreement: agreement, handoffFingerprint: handoff, firstOrdinal: owner.selectedTokenCount,
            previousTokenChainSHA256: owner.tokenChainSHA256)
        #expect(received.fingerprint == relay.fingerprint)
        var published: [Int] = []
        var last: QwenLayerStageGenerationDecisionPacket?
        for (index, token) in received.content.tokenIDs.enumerated() {
            last = try QwenPhaseSplitGeneration.replay(tokenID: token, payloadSHA256: received.content.payloadSHA256[index],
                control: owner) { published.append($0); return true }
            if last?.content.decision != .proceed { break }
        }
        #expect(published == [50, 51, 99] && owner.phase == .retiring && owner.finishReason == .eos)
        let verdict = try QwenPhaseSplitRelayDecisionPacket(agreement: agreement, relay: received, acceptedCount: 3,
            selectedTokenCount: owner.selectedTokenCount, tokenChainSHA256: owner.tokenChainSHA256,
            decision: try #require(last).content.decision)
        let answer = try QwenPhaseSplitRelayDecisionPacket.decode(try verdict.encoded(), agreement: agreement, relay: relay).content
        // Rank 1 replays what was published and must arrive at the same state.
        for index in 0..<answer.acceptedCount {
            let proceed = index + 1 < answer.acceptedCount || answer.decision == .proceed
            _ = try QwenPhaseSplitGeneration.replay(tokenID: relay.content.tokenIDs[index],
                payloadSHA256: relay.content.payloadSHA256[index], control: adopter) { _ in proceed }
        }
        #expect(adopter.phase == .retiring && adopter.finishReason == .eos)
        #expect(adopter.tokenChainSHA256 == owner.tokenChainSHA256 && adopter.tokenChainSHA256 == answer.tokenChainSHA256)
        #expect(adopter.selectedTokenCount == 4 && adopter.committedTokens == owner.committedTokens)
        #expect(adopter.completedFrames == owner.completedFrames && adopter.completedFrames == request.prefillFrameCount + 3)

        // A relay for another ordinal, history or hand-off is not this rank's next batch.
        let bytes = try relay.encoded()
        #expect(throws: ProbeError.self) { _ = try QwenPhaseSplitRelayPacket.decode(bytes, agreement: agreement, handoffFingerprint: handoff, firstOrdinal: 2, previousTokenChainSHA256: relay.content.previousTokenChainSHA256) }
        #expect(throws: ProbeError.self) { _ = try QwenPhaseSplitRelayPacket.decode(bytes, agreement: agreement, handoffFingerprint: handoff, firstOrdinal: 1, previousTokenChainSHA256: handoff) }
        #expect(throws: ProbeError.self) { _ = try QwenPhaseSplitRelayPacket.decode(bytes, agreement: agreement, handoffFingerprint: String(repeating: "8", count: 64), firstOrdinal: 1, previousTokenChainSHA256: relay.content.previousTokenChainSHA256) }
        // Bounds: the agreed batch size, the output limit, nothing after a stop token.
        func batch(_ first: Int, _ tokens: [Int]) throws {
            _ = try QwenPhaseSplitRelayPacket(agreement: agreement, handoffFingerprint: handoff, firstOrdinal: first,
                previousTokenChainSHA256: handoff, tokenIDs: tokens, payloadSHA256: tokens.indices.map(digest))
        }
        try batch(1, [1, 2, 3, 4]); try batch(2, [1, 2, 3, 4])
        #expect(throws: ProbeError.self) { try batch(1, [1, 2, 3, 4, 5]) }
        #expect(throws: ProbeError.self) { try batch(3, [1, 2, 3, 4]) }
        #expect(throws: ProbeError.self) { try batch(0, [1]) }
        #expect(throws: ProbeError.self) { try batch(1, []) }
        #expect(throws: ProbeError.self) { try batch(1, [99, 1]) }
        #expect(throws: ProbeError.self) { try batch(1, [248_320]) }
    }

    @Test func clientStopInsideABatchDiscardsTheRest() throws {
        let request = try PhaseSplitFixture.request(outputCount: 8)
        let agreement = try PhaseSplitFixture.agreement(request, relayBatchTokens: 4)
        let owner = try PhaseSplitFixture.controlAtHandoff(agreement), adopter = try PhaseSplitFixture.controlAtHandoff(agreement)
        let relay = try QwenPhaseSplitRelayPacket(agreement: agreement, handoffFingerprint: String(repeating: "7", count: 64),
            firstOrdinal: 1, previousTokenChainSHA256: adopter.tokenChainSHA256, tokenIDs: [50, 51, 52, 53],
            payloadSHA256: (1...4).map { sha256(Data("residual-\($0)".utf8)) })
        // The request owner stops after the second relayed token.
        var accepted = 0
        var last: QwenLayerStageGenerationDecisionPacket?
        for (index, token) in relay.content.tokenIDs.enumerated() {
            last = try QwenPhaseSplitGeneration.replay(tokenID: token, payloadSHA256: relay.content.payloadSHA256[index],
                control: owner) { $0 != 51 }
            accepted += 1
            if last?.content.decision != .proceed { break }
        }
        #expect(accepted == 2 && owner.finishReason == .clientStop && owner.selectedTokenCount == 3)
        let decision = try #require(last).content.decision
        let verdict = try QwenPhaseSplitRelayDecisionPacket(agreement: agreement, relay: relay, acceptedCount: accepted,
            selectedTokenCount: owner.selectedTokenCount, tokenChainSHA256: owner.tokenChainSHA256, decision: decision).content
        for index in 0..<verdict.acceptedCount {
            _ = try QwenPhaseSplitGeneration.replay(tokenID: relay.content.tokenIDs[index],
                payloadSHA256: relay.content.payloadSHA256[index], control: adopter) { _ in index + 1 < verdict.acceptedCount }
        }
        #expect(adopter.finishReason == .clientStop && adopter.tokenChainSHA256 == verdict.tokenChainSHA256)
        // Unpublished tokens may only be left behind by a stop.
        #expect(throws: ProbeError.self) {
            _ = try QwenPhaseSplitRelayDecisionPacket(agreement: agreement, relay: relay, acceptedCount: 2,
                selectedTokenCount: 3, tokenChainSHA256: owner.tokenChainSHA256, decision: .proceed)
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenPhaseSplitRelayDecisionPacket(agreement: agreement, relay: relay, acceptedCount: 2,
                selectedTokenCount: 4, tokenChainSHA256: owner.tokenChainSHA256, decision: .clientStop)
        }
        // The stage that decoded past the stop finishes with its extra forwards declared, and only then.
        var schedule = try QwenLayerStageGenerationSchedule(request: request, adoptedCommittedTokens: request.promptCount)
        #expect(schedule.committedTokens == 24 && schedule.nextSequence == request.prefillFrameCount)
        for _ in 0..<4 {
            let frame = try request.frame(sequence: schedule.nextSequence)
            try schedule.commit(frame)
        }
        var undeclared = schedule
        #expect(throws: ProbeError.self) { try undeclared.finish(.clientStop, selectedTokenCount: 3, lastTokenID: 51) }
        var masked = schedule
        #expect(throws: ProbeError.self) { try masked.finish(.length, selectedTokenCount: 3, lastTokenID: 51, discardedDecodeForwards: 2) }
        try schedule.finish(.clientStop, selectedTokenCount: 3, lastTokenID: 51, discardedDecodeForwards: 2)
        #expect(schedule.complete)
        // Adoption is only possible at the end of the prompt.
        #expect(throws: ProbeError.self) { _ = try QwenLayerStageGenerationSchedule(request: request, adoptedCommittedTokens: 23) }
    }

    @Test func handoffAllowanceIsNamedPerRank() throws {
        let request = try PhaseSplitFixture.request(promptCount: 8192, chunkSize: 512, outputCount: 128)
        let split = try #require(try PhaseSplitFixture.agreement(request, cut: 8).phaseSplit)
        let owner = try QwenPhaseSplitAllowance.derive(rank: 0, shapes: split.shapes, producerFusionBytes: 1000) { $0 + 16 }
        let adopter = try QwenPhaseSplitAllowance.derive(rank: 1, shapes: split.shapes, producerFusionBytes: 1000) { $0 + 16 }
        #expect(owner.extraHostBytes == split.terms.logicalBytes && adopter.extraHostBytes == split.terms.logicalBytes)
        #expect(owner.extraNativeBytes == split.terms.logicalBytes + 16 * 18)
        // Only the adopting rank also runs the producer stage.
        #expect(adopter.extraNativeBytes == owner.extraNativeBytes + 1000)
        #expect(throws: ProbeError.self) { _ = try QwenPhaseSplitAllowance.derive(rank: 0, shapes: split.shapes, producerFusionBytes: 0) { $0 - 1 } }
        #expect(throws: ProbeError.self) { _ = try QwenPhaseSplitAllowance.derive(rank: 2, shapes: split.shapes, producerFusionBytes: 0) { $0 } }
    }
}
