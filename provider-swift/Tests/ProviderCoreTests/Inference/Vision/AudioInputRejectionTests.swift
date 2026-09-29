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
