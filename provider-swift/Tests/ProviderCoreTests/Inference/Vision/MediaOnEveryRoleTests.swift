import CoreImage
import Foundation
import MLXLMCommon
import MLXLMServer
import MLXVLM
import Testing

@testable import ProviderCore

/// Images and videos in system, assistant and tool messages. The reference
/// server (vLLM) collects media from every role and lets the model's chat
/// template place it; an item the template leaves without a placeholder fails
/// the request with a 400. Before this, the provider kept only user-message
/// media: a request whose only image sat in another role was refused as
/// "invalid media", and beside a user image the others were dropped unseen.
@Suite("Media on every message role")
struct MediaOnEveryRoleTests {
    private static func imageURL(_ color: CIColor) throws -> String {
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let data = try #require(context.pngRepresentation(of: image, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        return "data:image/png;base64," + data.base64EncodedString()
    }

    private static func decode(_ messages: [[String: Any]]) throws -> OpenAIChatCompletionRequest {
        try JSONDecoder().decode(OpenAIChatCompletionRequest.self,
            from: JSONSerialization.data(withJSONObject: ["model": "vision-model", "messages": messages]))
    }

    private static func image(_ url: String) -> [String: Any] { ["type": "image_url", "image_url": ["url": url]] }
    private static func text(_ s: String) -> [String: Any] { ["type": "text", "text": s] }

    /// A system image (red), an assistant image (green), a tool-result image
    /// (blue) after an assistant tool call, and a user image (white).
    private static func everyRoleRequest() throws -> OpenAIChatCompletionRequest {
        let call: [String: Any] = ["id": "call-1", "type": "function",
                                   "function": ["name": "screenshot", "arguments": "{}"]]
        return try decode([
            ["role": "system", "content": [text("Reference:"), image(imageURL(.red))]],
            ["role": "user", "content": "Show me the picture."],
            ["role": "assistant", "content": [text("Here:"), image(imageURL(.green))]],
            ["role": "user", "content": "Now take a screenshot."],
            ["role": "assistant", "content": "", "tool_calls": [call]],
            ["role": "tool", "tool_call_id": "call-1", "content": [text("Screen:"), image(imageURL(.blue))]],
            ["role": "user", "content": [text("Compare them all."), image(imageURL(.white))]],
        ])
    }

    private static func color(_ image: UserInput.Image) throws -> [UInt8] {
        guard case .ciImage(let image) = image.source else { throw CocoaError(.coderInvalidValue) }
        var rgba = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.useSoftwareRenderer: true]).render(image, toBitmap: &rgba,
            rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return rgba
    }

    /// The template messages as sorted-key JSON: dictionary print order is
    /// not stable between two equal dictionaries.
    private static func rendered(_ input: UserInput) throws -> String {
        let messages = Gemma4MessageGenerator().generate(from: input)
        try #require(JSONSerialization.isValidJSONObject(messages))
        let data = try JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func nonUserMediaIsClassified() throws {
        #expect(MediaIngest.hasNonUserMedia(try Self.everyRoleRequest()))
        let userOnly = try Self.decode([["role": "system", "content": [Self.text("Be brief.")]],
                                        ["role": "user", "content": [Self.text("What is it?"), Self.image(Self.imageURL(.red))]]])
        #expect(!MediaIngest.hasNonUserMedia(userOnly))
    }

    /// Every message keeps its media, in message order, and its placeholder in
    /// its own role, with the tool-call fields the template needs to render the
    /// tool result. No inline bytes enter the template.
    @Test func everyRoleKeepsItsMediaInPlace() async throws {
        let input = try await MediaIngest.buildUserInput(from: Self.everyRoleRequest(), keepNonUserMedia: true)
        try #require(input.images.count == 4)
        #expect(try Self.color(input.images[0]) == [255, 0, 0, 255])
        #expect(try Self.color(input.images[1]) == [0, 255, 0, 255])
        #expect(try Self.color(input.images[2]) == [0, 0, 255, 255])
        #expect(try Self.color(input.images[3]) == [255, 255, 255, 255])
        guard case .messages(let messages) = input.prompt else { Issue.record("messages expected"); return }
        let withImage = messages.compactMap { message -> String? in
            guard let parts = message["content"] as? [[String: String]], parts.contains(where: { $0["type"] == "image" })
            else { return nil }
            return message["role"] as? String
        }
        #expect(withImage == ["system", "assistant", "tool", "user"])
        let tool = try #require(messages.first { $0["role"] as? String == "tool" })
        #expect(tool["tool_call_id"] as? String == "call-1")
        #expect(messages.contains { ($0["tool_calls"] as? [[String: any Sendable]])?.isEmpty == false })
        #expect(!String(describing: messages).contains("data:image"))
    }

    /// A request whose media sits only in user messages is built exactly as
    /// before, whatever the setting: same prompt messages, same images.
    @Test func userOnlyMediaIsUnchanged() async throws {
        let call: [String: Any] = ["id": "call-1", "type": "function",
                                   "function": ["name": "screenshot", "arguments": "{}"]]
        let request = try Self.decode([
            ["role": "system", "content": [Self.text("Be brief.")]],
            ["role": "user", "content": [Self.image(Self.imageURL(.red)), Self.text("What is it?")]],
            ["role": "assistant", "content": "", "tool_calls": [call]],
            ["role": "tool", "tool_call_id": "call-1", "content": [Self.text("done")]],
            ["role": "user", "content": [Self.text("And now?"), Self.image(Self.imageURL(.blue))]],
        ])
        let before = try await MediaIngest.buildUserInput(from: request)
        let after = try await MediaIngest.buildUserInput(from: request, keepNonUserMedia: true)
        #expect(try Self.rendered(after) == Self.rendered(before))
        #expect(after.images.count == 2 && before.images.count == 2)
        #expect(try after.images.map(Self.color) == before.images.map(Self.color))
    }

    /// With the switch off (`DARKBLOOM_MEDIA_ON_EVERY_ROLE=0`), the caller
    /// passes false: only user media is kept, as before.
    @Test func switchedOffKeepsOnlyUserMedia() async throws {
        let input = try await MediaIngest.buildUserInput(from: Self.everyRoleRequest(), keepNonUserMedia: false)
        #expect(input.images.count == 1)
        #expect(try Self.color(input.images[0]) == [255, 255, 255, 255])
    }

    /// The scans that must agree with the built input (`mediaKind`, the video
    /// budget, the pair's encoded bytes) read `messagesKeepingMedia`: its
    /// images are the input's, with media in every role or only in user
    /// messages, whatever the setting.
    @Test func messagesKeepingMediaMatchTheBuiltInput() async throws {
        let userOnly = try Self.decode([["role": "system", "content": [Self.text("Be brief.")]],
                                        ["role": "user", "content": [Self.text("What is it?"), Self.image(Self.imageURL(.red))]]])
        for request in try [Self.everyRoleRequest(), userOnly] {
            // The helper's images, in order, as the input decodes them.
            var kept: [UserInput.Image] = []
            for message in MediaIngest.messagesKeepingMedia(of: request) {
                guard case .parts(let parts) = message.content else { continue }
                for case .imageURL(let uri) in parts {
                    kept.append(try MediaIngest.decodeImageData(try MediaIngest.dataFromDataURI(uri)))
                }
            }
            let input = try await MediaIngest.buildUserInput(from: request,
                keepNonUserMedia: MediaIngest.placesNonUserMedia(request))
            try #require(kept.count == input.images.count)
            #expect(try kept.map(Self.color) == input.images.map(Self.color))
        }
        #expect(MediaIngest.messagesKeepingMedia(of: userOnly).map(\.role) == [OpenAIRole.user])
    }

    /// Media the template does not place is a client error on every provider:
    /// 400 `invalid_request` naming `media_role_not_rendered`, never the
    /// retriable 503 construction refusal.
    @Test func unrenderedMediaIsAClearClientError() throws {
        let fault = try #require(EngineV2VisionPrefill.clientFault(for: EngineV2VisionPrefillError.mediaRoleNotRendered))
        #expect(fault == .mediaRoleNotRendered)
        let failure = ProviderLoop.sanitizedInferenceFailure(from: fault, phase: .streamStart)
        #expect(failure.statusCode == 400)
        #expect(failure.code == .invalidRequest)
        #expect(failure.errorReason == .clientError)
        #expect(failure.refusal == .mediaRoleNotRendered)
    }

    /// GLM-5.3-Flash renders media in every role: a system image keeps its
    /// placeholder in the system message and its pixels in the input.
    @Test(.enabled(if: MediaIngest.everyRoleEnabled, "DARKBLOOM_MEDIA_ON_EVERY_ROLE is off"))
    func glmPlacesASystemImageInItsMessage() async throws {
        let request = try Self.decode([
            ["role": "system", "content": [Self.text("Reference:"), Self.image(Self.imageURL(.red))]],
            ["role": "user", "content": "What is the reference image?"],
        ])
        let input = try await EngineV2VisionPrefill.glm5NextUserInput(request: request, controls: .init())
        try #require(input.images.count == 1)
        #expect(try Self.color(input.images[0]) == [255, 0, 0, 255])
        guard case .messages(let messages) = input.prompt else { Issue.record("messages expected"); return }
        // GLM template values are Jinja values; only the system message carries parts here.
        let system = try #require(messages.first { $0["content"] is [[String: String]] })
        let parts = try #require(system["content"] as? [[String: String]])
        #expect(parts.map { $0["type"] } == ["text", "image"])
    }

    /// Which media-submission failures mean "the template did not place it".
    /// Tower, MLX and other processor faults keep their retriable refusal.
    @Test func unplacedMediaIsRecognized() {
        #expect(EngineV2VisionPrefill.isUnrenderedMedia(
            EngineV2VisionPrefillError.placeholderRunMissing(kind: .image, mediaIndex: 0)))
        #expect(EngineV2VisionPrefill.isUnrenderedMedia(
            EngineV2VisionPrefillError.unexpectedTrailingPlaceholders(kind: .image, count: 1)))
        #expect(EngineV2VisionPrefill.isUnrenderedMedia(EngineV2VisionPrefillError.noProcessedMedia))
        #expect(!EngineV2VisionPrefill.isUnrenderedMedia(EngineV2VisionPrefillError.towerFault(stage: "projector")))
        #expect(!EngineV2VisionPrefill.isUnrenderedMedia(
            EngineV2VisionPrefillError.placeholderRunTooShort(kind: .video, mediaIndex: 0, expected: 4)))
        #expect(!EngineV2VisionPrefill.isUnrenderedMedia(VLMError.processing("Qwen vision patch width differs from the loaded tower")))
        #expect(!EngineV2VisionPrefill.isUnrenderedMedia(CancellationError()))
    }

    private struct TemplateRaise: Error, CustomStringConvertible {
        let description: String
    }

    /// The processor's refusals that mean "the template did not place it":
    /// the template's own media raise and Qwen's placeholder count check, and
    /// nothing else.
    @Test func templatePlacementRefusalsAreRecognized() {
        #expect(EngineV2VisionPrefill.isTemplatePlacementRefusal(
            TemplateRaise(description: "TemplateException: System message cannot contain images.")))
        #expect(EngineV2VisionPrefill.isTemplatePlacementRefusal(
            TemplateRaise(description: "TemplateException: System message cannot contain videos.")))
        #expect(EngineV2VisionPrefill.isTemplatePlacementRefusal(
            VLMError.processing(EngineV2VisionPrefill.qwenPlaceholderCountMismatch)))
        #expect(!EngineV2VisionPrefill.isTemplatePlacementRefusal(
            TemplateRaise(description: "TemplateException: System message must be at the beginning.")))
        #expect(!EngineV2VisionPrefill.isTemplatePlacementRefusal(
            TemplateRaise(description: "cannot contain images")))
        #expect(!EngineV2VisionPrefill.isTemplatePlacementRefusal(
            VLMError.processing("Qwen vision patch width differs from the loaded tower")))
    }

    /// The real template path: a chat template's `raise_exception` for a
    /// system image, thrown through `applyChatTemplate`, is recognized; a
    /// different raise is not.
    @Test func aRealTemplateMediaRaiseIsRecognized() async throws {
        let template = """
            {%- for message in messages -%}
            {%- if message['role'] == 'system' and message['content'] is not string -%}{{- raise_exception('System message cannot contain images.') -}}{%- endif -%}
            {%- if message['role'] == 'assistant' -%}{{- raise_exception('Assistant turns are not supported.') -}}{%- endif -%}
            {{- message['role'] -}}
            {%- endfor -%}
            """
        let fixture = try SyntheticTokenizer(family: .qwen, template: template)
        let tokenizer = try await LocalTokenizerLoader(environment: [:]).load(from: fixture.directory)
        let systemImage: [[String: any Sendable]] = [
            ["role": "system", "content": [["type": "image"], ["type": "text", "text": "Reference"]]],
            ["role": "user", "content": "What is it?"]]
        do {
            _ = try tokenizer.applyChatTemplate(messages: systemImage, tools: nil, additionalContext: nil)
            Issue.record("the template's raise was expected")
        } catch {
            #expect(EngineV2VisionPrefill.isTemplatePlacementRefusal(error), "\(error)")
        }
        let assistant: [[String: any Sendable]] = [["role": "user", "content": "hi"], ["role": "assistant", "content": "hello"]]
        do {
            _ = try tokenizer.applyChatTemplate(messages: assistant, tools: nil, additionalContext: nil)
            Issue.record("the template's raise was expected")
        } catch {
            #expect(!EngineV2VisionPrefill.isTemplatePlacementRefusal(error), "\(error)")
        }
    }

    /// One placeholder run per expanded image, whatever its length.
    @Test func placeholderRunsCountExpandedImages() {
        let image = 7
        #expect(EngineV2VisionPrefill.placeholderRuns(in: [1, 2, 3], of: image) == 0)
        #expect(EngineV2VisionPrefill.placeholderRuns(in: [1, 9, image, image, image, 8, 2], of: image) == 1)
        #expect(EngineV2VisionPrefill.placeholderRuns(in: [9, image, image, 8, 9, image, 8, image], of: image) == 3)
    }

    /// GLM keeps an instruction its text policy appends to a system message
    /// (here `tool_choice: none`) after that message's media parts.
    @Test(.enabled(if: MediaIngest.everyRoleEnabled, "DARKBLOOM_MEDIA_ON_EVERY_ROLE is off"))
    func glmKeepsAnAppendedSystemInstruction() async throws {
        let body: [String: Any] = ["model": "vision-model", "tool_choice": "none",
            "tools": [["type": "function", "function": ["name": "screenshot", "parameters": ["type": "object", "properties": [:]]]]],
            "messages": [["role": "system", "content": [Self.text("Reference:"), Self.image(try Self.imageURL(.red))]],
                         ["role": "user", "content": "What is the reference image?"]]]
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self,
            from: JSONSerialization.data(withJSONObject: body))
        let input = try await EngineV2VisionPrefill.glm5NextUserInput(request: request, controls: .init())
        guard case .messages(let messages) = input.prompt else { Issue.record("messages expected"); return }
        // GLM template values are Jinja values; only the system message carries parts here.
        let system = try #require(messages.first { $0["content"] is [[String: String]] })
        let parts = try #require(system["content"] as? [[String: String]])
        #expect(parts.prefix(2).map { $0["type"] } == ["text", "image"])
        #expect(parts.count == 3 && parts[2]["type"] == "text")
        #expect(parts.last?["text"] == "\n\nDo not call any tool. Answer the user directly without emitting a tool call.")
    }

    /// `DARKBLOOM_MEDIA_ON_EVERY_ROLE` is this change's switch: an installed
    /// service must receive it.
    @Test func everyRoleSwitchIsForwardedToTheService() {
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(MediaIngest.everyRoleEnvironmentKey))
        let forwarded = LaunchAgent.passthroughEnvironment(from: [MediaIngest.everyRoleEnvironmentKey: "0"])
        #expect(forwarded[MediaIngest.everyRoleEnvironmentKey] == "0")
    }
}
