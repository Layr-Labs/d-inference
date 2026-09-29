import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Unsupported audio input rejection")
struct AudioInputRejectionTests {
    private enum UnexpectedWork: Error { case modelAcquisition, tokenization }

    private actor AcquisitionProbe {
        private(set) var count = 0
        func record() { count += 1 }
    }

    private final class HandlerProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [OutboundMessage] = []
        private var builds = 0
        func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
        func recordBuild() { lock.withLock { builds += 1 } }
        var snapshot: [OutboundMessage] { lock.withLock { messages } }
        var buildCount: Int { lock.withLock { builds } }
    }

    private struct RejectingTokenizer: MLXLMCommon.Tokenizer {
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
        func convertTokenToId(_ token: String) -> Int? { nil }
        func convertIdToToken(_ id: Int) -> String? { nil }
        var bosToken: String? { nil }
        var eosToken: String? { nil }
        var unknownToken: String? { nil }
        func applyChatTemplate(
            messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            throw UnexpectedWork.tokenization
        }
    }

    private func request(_ shape: Int, role: OpenAIRole = .user) -> OpenAIChatCompletionRequest {
        let audio = OpenAIContentPart.inputAudio(.init(data: "private-audio-payload", format: .wav))
        let parts: [OpenAIContentPart]
        switch shape {
        case 0: parts = [audio]
        case 1: parts = [.text("transcribe this"), audio]
        case 2: parts = [.imageURL("file:///must-not-be-decoded"), audio]
        default: parts = [.videoURL("file:///must-not-be-decoded"), .text("describe"), audio]
        }
        return .init(
            model: "test/audio-unsupported", messages: [.init(role: role, content: .parts(parts))])
    }

    private func assertUnsupported(_ error: Error) {
        guard let typed = error as? MultiModelBatchSchedulerEngineError,
            case .multimodalRejected(let message) = typed
        else {
            Issue.record("expected the explicit unsupported-audio refusal, got \(type(of: error))")
            return
        }
        #expect(message == "multimodal_rejected: input_audio is not supported")
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .streamStart)
        #expect(failure.code == .invalidMedia)
        #expect(failure.errorReason == .clientError)
    }

    @Test("new SDK audio wire parts remain media and never receive a finite resource estimate")
    func wireAndProjection() throws {
        let decoded = try ProviderLoop.decodeOpenAIRequest(JSONEncoder().encode(request(0)))
        guard case .parts(let parts) = decoded.messages[0].content,
            let first = parts.first, case .inputAudio = first
        else {
            Issue.record("audio wire part was lost")
            return
        }
        #expect(MediaIngest.hasMedia(decoded))
        #expect(!MediaIngest.hasVideo(decoded))
        #expect(MediaIngest.projectedDecodeBytes(decoded) == .max)
        #expect(
            MediaIngest.projectedKVTokens(decoded, defaultMaxTokens: 64, contextLength: 4096)
                == .max)
    }

    @Test("audio-only and mixed requests refuse before model acquisition", arguments: [0, 1, 2, 3])
    func beforeModelAcquisition(shape: Int) async {
        let probe = AcquisitionProbe()
        let engine = MultiModelBatchSchedulerEngine(
            acquire: { _ in
                await probe.record()
                throw UnexpectedWork.modelAcquisition
            },
            tokenizerProvider: { _ in throw UnexpectedWork.tokenization },
            availableModels: { [] })
        do {
            _ = try await engine.streamChatCompletion(request: request(shape))
            Issue.record("unsupported audio reached serving")
        } catch { assertUnsupported(error) }
        #expect(await probe.count == 0)
    }

    @Test(
        "every role rejects audio before decoding earlier media or rendering native templates",
        arguments: [OpenAIRole.user, .assistant, .system, .tool], [false, true])
    func beforeMediaDecoding(role: OpenAIRole, preserveTemplateFields: Bool) async {
        for shape in 0 ... 3 {
            do {
                _ = try await MediaIngest.buildUserInput(
                    from: request(shape, role: role),
                    preserveTemplateFields: preserveTemplateFields,
                    modelType: preserveTemplateFields ? "diffusion_gemma" : nil)
                Issue.record("unsupported audio was discarded")
            } catch { assertUnsupported(error) }
        }
    }

    @Test("prompt-contract tokenization rejects audio before flattening", arguments: [0, 1, 2, 3])
    func beforePromptTemplate(shape: Int) throws {
        let request = request(shape)
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        do {
            _ = try ProviderPromptContractPipeline.tokenize(
                prepared: prepared, request: request, tokenizer: RejectingTokenizer(),
                modelType: nil, templateControls: .init())
            Issue.record("audio request was tokenized")
        } catch { assertUnsupported(error) }
        do {
            _ = try ProviderPromptContractPipeline.tokenizeProviderBody(
                JSONEncoder().encode(request), tokenizer: RejectingTokenizer(), modelType: nil)
            Issue.record("wire audio request was tokenized")
        } catch { assertUnsupported(error) }
    }

    @Test(
        "encrypted audio refuses before acceptance or cold-model load and finalizes receipts",
        arguments: [0, 1, 2, 3], [1, 2])
    func encryptedIngressBeforeAcceptance(shape: Int, prefixProtocol: Int) async throws {
        let hardware = HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: .init(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let loop = try ProviderLoop(
            config: .init(
                coordinatorURL: "ws://127.0.0.1:0/unused", hardware: hardware, models: [],
                config: .init(
                    provider: .init(name: "audio-ingress-test", memoryReserveGB: 1),
                    backend: .init(idleTimeoutMins: 0, maxModelSlots: 1),
                    coordinator: .init(heartbeatIntervalSecs: 60))), attestationSigner: nil)
        let probe = HandlerProbe()
        await loop.setEngineV2SlotHooksForTesting(
            .init(makeEngine: { _, _ in
                probe.recordBuild()
                return InertStubEngine()
            }))
        var input = request(shape)
        input.model = "test/absent-audio-model-" + UUID().uuidString
        let requestID = "encrypted-audio-" + UUID().uuidString
        let nonce = "audio-policy-nonce"
        let reservationID = UUID().uuidString.lowercased()
        let sender = NodeKeyPair.generate()
        let encrypted = try sender.encrypt(
            recipientPublicKey: await loop.keyPair.publicKeyBytes,
            plaintext: JSONEncoder().encode(input))
        // This existing profile hook records entry into ensureModelLoaded's
        // call site even if a nonexistent model fails before engine creation.
        let profile = RequestProfileBuilder()
        await loop.handleInferenceRequest(
            requestId: requestID, ciphertext: encrypted,
            senderPublicKey: sender.publicKeyBytes, cacheReceiptNonce: nonce,
            authenticatedCacheScope: "audio-policy-scope", prefixCacheProtocol: prefixProtocol,
            cacheReceiptBoundaryMode: "checkpoint", profile: profile,
            serviceReservationID: reservationID, send: SendHandle(probe.record))

        var kinds: [String] = []
        var failures: [InferenceFailure] = []
        for message in probe.snapshot {
            switch message {
            case .prefixCacheLookup(let id, let receiptNonce, let outcome, _, _, _, _):
                kinds.append("lookup")
                #expect(id == requestID && receiptNonce == nonce)
                #expect(outcome == .skippedPolicy)
            case .inferenceError(let id, let failure, let errorProfile):
                kinds.append("error")
                #expect(id == requestID)
                #expect(errorProfile === profile)
                failures.append(failure)
            case .serviceReservationReleased(let id):
                kinds.append("released")
                #expect(id == reservationID)
            default:
                // Includes inferenceAccepted, load status, chunks and completions.
                kinds.append("unexpected")
            }
        }
        // V2 has no configured lookup emitter before model admission. Preserve
        // that contract; never manufacture a legacy receipt for a V2 request.
        #expect(
            kinds
                == (prefixProtocol == 1 ? ["lookup", "error", "released"] : ["error", "released"]))
        #expect(failures.count == 1)
        let failure = try #require(failures.first)
        #expect(failure.statusCode == 400)
        #expect(failure.code == .invalidMedia)
        #expect(failure.errorReason == .clientError)
        #expect(failure.message == InferenceFailureCode.invalidMedia.message)
        let observed = profile.wireObject()
        #expect(observed.decryptedUs != nil && observed.parsedUs != nil)
        #expect(observed.acceptedSentUs == nil && observed.loadWaitStartUs == nil)
        #expect(observed.loadCold == nil && observed.taskSpawnedUs == nil)
        #expect(probe.buildCount == 0)
        #expect(await loop.modelSlots.isEmpty)
        #expect(await loop.modelsLoading.isEmpty)
        #expect(await loop.requestToModel[requestID] == nil)
        #expect(await loop.inflightProfiles[requestID] == nil)
        #expect(await loop.acceptedLifecycleRequests.isEmpty)
    }

    @Test("existing text, image and video inputs pass audio validation")
    func supportedPartsUnchanged() throws {
        for part in [
            OpenAIContentPart.text("hello"), .imageURL("data:image/png;base64,AA=="),
            .videoURL("data:video/mp4;base64,AA=="),
        ] {
            try MediaIngest.rejectUnsupportedAudio(
                .init(
                    model: "test/model", messages: [.init(role: .user, content: .parts([part]))]))
        }
    }
}
