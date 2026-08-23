// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("MultiModelBatchSchedulerEngine vision-v2 error mapping and security")
struct EngineV2VisionErrorSecurityTests {
    @Test("construction failure REFUSES loudly: ERROR telemetry + 503, no legacy fallback")
    func constructionFailureRefusesLoudly() async throws {
        struct PrepFailure: Error {}
        // Real budget behind the slot's gate so the vision reservation is
        // NOT a no-op: the refusal path must release it (a leak would shrink
        // admission headroom one refused request at a time).
        let (gate, budget) = visionMakeBudgetedVisionGate()
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = visionMakeBridge(engine: engine)
        let telemetry = VisionTelemetrySink()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in throw PrepFailure() },
            emitTelemetry: telemetry.callback()
        )
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(),
            bridge: bridge, plumbing: plumbing, visionGate: gate)

        // The stub container's processor would throw VisionStubProcessorError
        // if any fallback ever consulted it — seeing `.requestRejected`
        // instead is the proof the request was REFUSED, never re-served.
        do {
            _ = try await visionCollectContent(
                try await router.streamChatCompletion(request: visionImageRequest()))
            Issue.record("expected requestRejected throw")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .requestRejected(let message) = error else {
                Issue.record("expected .requestRejected, got \(error)")
                return
            }
            #expect(message.contains("media=image"))
            // Retriable 503 → the coordinator's pre-content failover
            // reroutes to another provider.
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 503)
        } catch {
            Issue.record("expected MultiModelBatchSchedulerEngineError, got \(error)")
        }
        #expect(engine.submitted.isEmpty, "the engine must never see a failed construction")
        #expect(await budget.outstandingReservedBytes() == 0)

        let refusals = telemetry.events.filter {
            $0.fields?["operation"]?.description == "engine_v2_vision_refusal"
        }
        #expect(refusals.count == 1)
        #expect(refusals.first?.severity == .error)
        #expect(refusals.first?.fields?["multimodal"]?.description == "true")
        #expect(refusals.first?.fields?["media_kind"]?.description == "image")
        #expect(
            refusals.first?.fields?["error_class"]?.description.contains("PrepFailure") == true)
        // No fallback WARN exists anymore.
        #expect(
            telemetry.events.allSatisfy {
                $0.fields?["operation"]?.description != "engine_v2_vision_fallback"
            })
    }

    @Test("MediaError out of construction keeps its deterministic 4xx (not a refusal)")
    func mediaErrorFromConstructionKeeps4xx() async throws {
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = visionMakeBridge(engine: engine)
        let telemetry = VisionTelemetrySink()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in
                throw MediaIngest.MediaError.mediaTooLarge("test-cap")
            },
            emitTelemetry: telemetry.callback()
        )
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        do {
            _ = try await visionCollectContent(
                try await router.streamChatCompletion(request: visionImageRequest()))
            Issue.record("expected MediaError throw")
        } catch let error as MediaIngest.MediaError {
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        } catch {
            Issue.record("expected MediaError, got \(error)")
        }
        #expect(engine.submitted.isEmpty)
        // A client input fault is not a v2 refusal — no ERROR event.
        #expect(
            telemetry.events.allSatisfy {
                $0.fields?["operation"]?.description != "engine_v2_vision_refusal"
            })
    }

    @Test("noProcessedMedia (media on non-user roles only) maps to 400, not a refusal")
    func noProcessedMediaMapsTo400() async throws {
        // Without this mapping the shape would 503 → the coordinator's
        // failover would burn retries on a request that fails identically
        // on every provider (buildUserInput drops non-user media
        // everywhere).
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = visionMakeBridge(engine: engine)
        let telemetry = VisionTelemetrySink()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in throw EngineV2VisionPrefillError.noProcessedMedia },
            emitTelemetry: telemetry.callback()
        )
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        do {
            _ = try await visionCollectContent(
                try await router.streamChatCompletion(request: visionImageRequest()))
            Issue.record("expected multimodalRejected throw")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .multimodalRejected(let message) = error else {
                Issue.record("expected .multimodalRejected, got \(error)")
                return
            }
            #expect(message.hasPrefix("multimodal_rejected:"))
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        } catch {
            Issue.record("expected MultiModelBatchSchedulerEngineError, got \(error)")
        }
        #expect(engine.submitted.isEmpty)
        // A deterministic client shape is not a v2 refusal — no ERROR event.
        #expect(
            telemetry.events.allSatisfy {
                $0.fields?["operation"]?.description != "engine_v2_vision_refusal"
            })
    }

    @Test("unsupported Qwen video maps to deterministic 400 without refusal telemetry")
    func unsupportedVideoMapsTo400() async throws {
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = visionMakeBridge(engine: engine)
        let telemetry = VisionTelemetrySink()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in
                throw EngineV2VisionPrefillError.unsupportedMedia(
                    "Qwen35MoE video media is not production-proven")
            },
            emitTelemetry: telemetry.callback())
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(), bridge: bridge, plumbing: plumbing)

        do {
            _ = try await visionCollectContent(
                try await router.streamChatCompletion(request: visionImageRequest()))
            Issue.record("expected multimodalRejected throw")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .multimodalRejected(let message) = error else {
                Issue.record("expected .multimodalRejected, got \(error)")
                return
            }
            #expect(message.contains("video media is not production-proven"))
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        }
        #expect(engine.submitted.isEmpty)
        #expect(
            telemetry.events.allSatisfy {
                $0.fields?["operation"]?.description != "engine_v2_vision_refusal"
            })
    }

    @Test("refusal on a video request tags media_kind video")
    func refusalTagsVideoKind() async throws {
        struct PrepFailure: Error {}
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = visionMakeBridge(engine: engine)
        let telemetry = VisionTelemetrySink()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in throw PrepFailure() },
            emitTelemetry: telemetry.callback()
        )
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        // Real tinyMP4 so validateMedia passes and the preparer is reached.
        let request = visionImageRequest(parts: [
            .text("what happens in this clip?"), .videoURL(visionTinyMP4DataURI),
        ])
        do {
            _ = try await visionCollectContent(
                try await router.streamChatCompletion(request: request))
            Issue.record("expected requestRejected throw")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .requestRejected(let message) = error else {
                Issue.record("expected .requestRejected, got \(error)")
                return
            }
            #expect(message.contains("media=video"))
        } catch {
            Issue.record("expected MultiModelBatchSchedulerEngineError, got \(error)")
        }
        let refusals = telemetry.events.filter {
            $0.fields?["operation"]?.description == "engine_v2_vision_refusal"
        }
        #expect(refusals.count == 1)
        #expect(refusals.first?.fields?["media_kind"]?.description == "video")
    }

    @Test("non-bridged slot fails LOUD on media (no legacy wrapper path left)")
    func nonBridgedSlotFailsLoud() async throws {
        // ONE ENGINE (v0.7.5): the legacy VLM wrapper stream is deleted.
        // Every production slot carries a v2 bridge, so a media request on a
        // bridge-less slot is a wiring bug — a hard internal error (500-
        // shaped generationFailed), never a silent legacy serve. The
        // preparer must not be consulted on the way to the backstop.
        let counter = VisionPrepareCallCounter()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in
                counter.increment()
                throw VisionStubProcessorError()
            },
            emitTelemetry: { _ in }
        )
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(),
            bridge: nil, plumbing: plumbing)
        do {
            _ = try await visionCollectContent(
                try await router.streamChatCompletion(request: visionImageRequest()))
            Issue.record("expected generationFailed throw")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .generationFailed(let message) = error else {
                Issue.record("expected .generationFailed, got \(error)")
                return
            }
            #expect(message.contains("no serving engine for media"))
        }
        #expect(counter.count == 0)
    }

    @Test("garbage inline video still dies in validateMedia (4xx) before the preparer")
    func garbageVideoRejectedBeforePreparer() async throws {
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = visionMakeBridge(engine: engine)
        let counter = VisionPrepareCallCounter()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in
                counter.increment()
                throw VisionStubProcessorError()
            },
            emitTelemetry: { _ in }
        )
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(),
            bridge: bridge, plumbing: plumbing)
        // The garbage inline video dies in `validateMedia` (a 400-class
        // MediaError) BEFORE the v2 attempt — the preparer must not fire
        // and the engine must stay untouched.
        let request = visionImageRequest(parts: [
            .imageURL(visionTinyPNGDataURI), .videoURL("data:video/mp4;base64,AAAA"),
        ])
        do {
            _ = try await visionCollectContent(
                try await router.streamChatCompletion(request: request))
            Issue.record("expected MediaError throw")
        } catch let error as MediaIngest.MediaError {
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        } catch {
            Issue.record("expected MediaError, got \(error)")
        }
        #expect(counter.count == 0)
        #expect(engine.submitted.isEmpty)
    }

    @Test("cancel during vision construction propagates as cancellation (499), not refusal or 500")
    func cancelDuringVisionConstructionPropagatesCancellation() async throws {
        // The consumer cancelled while the vision features were being built
        // (handleCancellation cancels the request task; the preparer's
        // container/tokenizer work observes it as CancellationError). The
        // routing seam must NOT burn a refusal ERROR or reject the request
        // — it releases and rethrows — and the handler-side mapping must
        // report the canonical cancellation (499), never a 500
        // .inferenceError (which would count as a provider fault and trip
        // the (provider, model) 5xx routing cooldown for a client's own
        // cancel).
        let (gate, budget) = visionMakeBudgetedVisionGate()
        let engine = VisionScriptedEngine(script: .stream([]))
        let bridge = visionMakeBridge(engine: engine)
        let telemetry = VisionTelemetrySink()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in throw CancellationError() },
            emitTelemetry: telemetry.callback()
        )
        let releaseCount = VisionPrepareCallCounter()
        let container = visionMakeStubContainer()
        let router = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [
                    "test/vlm-stub": .init(
                        tokenizer: TokenizerHandle(VisionStubTokenizer()),
                        modelType: "gemma4",
                        container: container,
                        isVLM: true,
                        engineV2Bridge: bridge,
                        visionGate: gate)
                ]
            },
            releaseModel: { @Sendable _ in releaseCount.increment() },
            defaultMaxTokens: 64,
            engineV2Vision: plumbing
        )

        do {
            _ = try await visionCollectContent(
                try await router.streamChatCompletion(request: visionImageRequest()))
            Issue.record("expected CancellationError throw")
        } catch is CancellationError {
            // Handler-side contract: the pre-stream catch reports this as
            // the canonical cancellation, and the generic mapper backstops
            // every other call site with 499 — never 500.
            #expect(ProviderLoop.mapInferenceErrorToStatus(CancellationError()) == 499)
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        // No refusal ERROR (this was not a v2 failure), engine untouched
        // (never submitted), model reservation released exactly once, and
        // the vision memory reservation fully released.
        #expect(
            telemetry.events.allSatisfy {
                $0.fields?["operation"]?.description != "engine_v2_vision_refusal"
            })
        #expect(engine.submitted.isEmpty)
        #expect(releaseCount.count == 1)
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("engine-side CBv2MultimodalError surfaces as .multimodalRejected → 400")
    func engineMultimodalRejectionMapsTo400() async throws {
        let engine = VisionScriptedEngine(
            script: .throwOnSubmit(CBv2MultimodalError.invalidSpans("test detail")))
        let bridge = visionMakeBridge(engine: engine)
        let (prepared, _) = visionMakePreparedSubmission()
        let plumbing = EngineV2VisionPlumbing(
            prepare: { _, _, _ in prepared },
            emitTelemetry: { _ in }
        )
        let router = visionMakeRoutingEngine(
            container: visionMakeStubContainer(),
            bridge: bridge, plumbing: plumbing)

        do {
            _ = try await visionCollectContent(
                try await router.streamChatCompletion(request: visionImageRequest()))
            Issue.record("expected multimodalRejected throw")
        } catch let error as MultiModelBatchSchedulerEngineError {
            guard case .multimodalRejected(let message) = error else {
                Issue.record("expected .multimodalRejected, got \(error)")
                return
            }
            #expect(message.hasPrefix("multimodal_rejected:"))
            #expect(message.contains("test detail"))
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        }
    }
}

// MARK: - Error-message mapping units

@Suite("CBv2MultimodalError → multimodal_rejected mapping")
struct MultimodalErrorMappingTests {

    @Test("every CBv2MultimodalError case maps to the multimodal_rejected prefix")
    func admissionMessages() {
        let cases: [CBv2MultimodalError] = [
            .unsupportedModel("m"),
            .unsupportedBackend("b"),
            .invalidSpans("s"),
            .spanTooLong(blockTokens: 560, maxBatchedTokensPerStep: 512),
            .embeddingMismatch("e"),
        ]
        for error in cases {
            let message = EngineV2Translation.admissionErrorMessage(for: error)
            #expect(
                message.hasPrefix(EngineV2Translation.multimodalRejectedPrefix),
                Comment(rawValue: "case \(error) mapped to \(message)"))
            // And the round trip: message → typed error → 400.
            let typed = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
            guard case .multimodalRejected = typed else {
                Issue.record("expected .multimodalRejected for \(message), got \(typed)")
                continue
            }
            #expect(ProviderLoop.mapInferenceErrorToStatus(typed) == 400)
        }
    }

    @Test("spanTooLong carries both figures in the message")
    func spanTooLongMessage() {
        let message = EngineV2Translation.admissionErrorMessage(
            for: CBv2MultimodalError.spanTooLong(
                blockTokens: 560, maxBatchedTokensPerStep: 512))
        #expect(message.contains("560"))
        #expect(message.contains("512"))
    }

    @Test("capacity errors are unaffected by the new prefix check")
    func capacityErrorsUnchanged() {
        let message = EngineV2Translation.admissionErrorMessage(
            for: CBv2KVError.capacityExhausted(needed: 100, available: 10))
        let typed = MultiModelBatchSchedulerEngineError.fromSchedulerMessage(message)
        #expect(typed == .tokenBudgetExhausted(message))
    }
}
