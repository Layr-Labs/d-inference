// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Exact-artifact acceptance test for the Qwen3.8 launch pair.
///
/// This is intentionally opt-in: it loads roughly 17 GiB of target weights,
/// exercises the real Metal vision path, then rebuilds the production bundle
/// with the separate MTP artifact. The test resolves normal Hugging Face cache
/// snapshots, but stages the assistant's config and weight as regular hard
/// links because the production local-artifact trust boundary rejects symlinks.
@Suite("Qwen3.8 production artifact canary", .serialized)
struct Qwen38ProductionCanaryTests {
    @Test(
        "full VLM request surface and one-layer MTP remain target-authoritative",
        .enabled(
            if: Qwen38ProductionCanary.enabled,
            "set DARKBLOOM_LIVE_MLX_TESTS=1 and DARKBLOOM_LIVE_MLX_QWEN38=1 to run the local real-artifact Qwen3.8 canary")
    )
    func fullVLMAndSeparateMTPArtifact() async throws {
        let fixture = try await Qwen38ProductionCanary.load()
        defer { fixture.removeStagedAssistant() }
        #expect(fixture.assistantLayerCount == 1)

        var liveBundle: ProviderEngineBundle?
        do {
            let targetBundle = try await fixture.makeBundle(
                preparation: .init(
                    artifact: nil,
                    status: .disabled(.configDisabled, configured: false)))
            liveBundle = targetBundle
            let targetService = fixture.service(bundle: targetBundle)

            if !Qwen38ProductionCanary.mtpOnly {
                try await fixture.checkText(using: targetService)
                try await fixture.checkStreaming(using: targetService)
                try await fixture.checkJSON(using: targetService)
                try await fixture.checkReasoning(using: targetService)
                try await fixture.checkRequiredTool(using: targetService)
                try await fixture.checkImage(using: targetService)
                try await fixture.checkMultipleImages(using: targetService)
                try await fixture.checkVideo(using: targetService)
                try await fixture.checkMixedMedia(using: targetService)
            }

            let parityPrompt = try fixture.tokenize(fixture.parityRequest())
            let targetRun = try await Qwen38ProductionCanary.timedRawTokens(
                bundle: targetBundle,
                promptTokens: parityPrompt,
                maxTokens: Qwen38ProductionCanary.parityMaxTokens,
                requestID: Qwen38ProductionCanary.parityRequestID)
            #expect(targetRun.tokens.count > 32, "parity request did not exercise a long decode")

            await Qwen38ProductionCanary.retire(targetBundle)
            liveBundle = nil

            let preparation = await fixture.separateMTPPreparation()
            let artifact = try #require(
                preparation.artifact,
                "SpecDecArtifactFunnel did not resolve the staged Qwen3.8 MTP artifact")
            #expect(artifact.source == .local)
            #expect(preparation.status.configured)

            let mtpBundle = try await fixture.makeBundle(preparation: preparation)
            liveBundle = mtpBundle
            let initialMTP = await mtpBundle.bridge.mtpStatusSnapshot()
            #expect(initialMTP.configured)
            #expect(initialMTP.active)
            #expect(initialMTP.assistantSource == .local)
            #expect(initialMTP.assistantResidentBytes > 0)
            #expect(mtpBundle.assistantBytes > 0)

            _ = try await Qwen38ProductionCanary.rawTokens(
                bundle: mtpBundle,
                promptTokens: parityPrompt,
                maxTokens: Qwen38ProductionCanary.mtpWarmupMaxTokens,
                requestID: Qwen38ProductionCanary.warmupRequestID)
            _ = try await Qwen38ProductionCanary.waitForIdle(mtpBundle.bridge)

            let mtpRun = try await Qwen38ProductionCanary.timedRawTokens(
                bundle: mtpBundle,
                promptTokens: parityPrompt,
                maxTokens: Qwen38ProductionCanary.parityMaxTokens,
                requestID: Qwen38ProductionCanary.parityRequestID)
            if Qwen38ProductionCanary.serialMTP {
                #expect(
                    mtpRun.tokens == targetRun.tokens,
                    "serial-oracle MTP changed greedy emitted token IDs")
            } else {
                #expect(
                    mtpRun.tokens.count == targetRun.tokens.count,
                    "rectangular MTP changed the requested decode length")
            }

            let mtp = await mtpBundle.bridge.mtpStatusSnapshot()
            #expect(mtp.active)
            #expect(mtp.proposedTokens > 0)
            #expect(mtp.acceptedDraftTokens > 0)
            if Qwen38ProductionCanary.serialMTP {
                #expect(mtp.serialVerificationRounds > 0)
                #expect(mtp.rectangularVerificationRounds == 0)
                #expect(mtp.verificationMode == CBv2MTPVerificationMode.serialTarget.rawValue)
            } else {
                #expect(mtp.rectangularVerificationRounds > 0)
                #expect(mtp.serialVerificationRounds == 0)
                #expect(mtp.verificationMode == CBv2MTPVerificationMode.rectangular.rawValue)
            }
            // The one-layer artifact is recurrently applied for an adaptive
            // multi-token draft. Layer depth and draft depth are distinct.
            #expect((0 ... 4).contains(mtp.selectedDepth))
            #expect(mtp.acceptanceByPosition.count <= 4)

            print(Qwen38ProductionCanary.benchmarkDiagnostic(
                target: targetRun,
                mtp: mtpRun,
                proposed: mtp.proposedTokens,
                accepted: mtp.acceptedDraftTokens))

            let drained = try await Qwen38ProductionCanary.waitForIdle(mtpBundle.bridge)
            #expect(drained.activeRequests == 0)
            #expect(drained.waitingRequests == 0)
            #expect(drained.activeTokens == 0)
            #expect(drained.kvBytesInUse == 0)
            #expect(drained.kvBytesReserved == 0)

            await Qwen38ProductionCanary.retire(mtpBundle)
            liveBundle = nil
        } catch {
            if let liveBundle {
                await Qwen38ProductionCanary.retire(liveBundle)
            }
            throw error
        }
    }
}
