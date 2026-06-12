import XCTest

@testable import ProviderCoreFoundation

/// Fixture-driven tests for the scan-time template-render self-check
/// (DAR-130 class). Each test fabricates a temp model snapshot directory
/// with controlled template files and asserts the tri-state result:
/// true (all canonical fixtures render), false (any fixture throws — the
/// routing signal), nil (no template found — unknown).
final class TemplateRenderCheckTests: XCTestCase {

    // MARK: - Template fixtures

    /// A correct, minimal gemma-style template: keeps the load-bearing
    /// patterns of the real gemma-4 `chat_template.jinja` — the
    /// `messages[0]['content'] | trim` system block, the tool-declaration
    /// macro applying `{{ value['type'] | upper }}` over schema nodes
    /// (the DAR-130 pattern — safe against post-normalization fixtures,
    /// where every node has a string `type`), the `tool_calls`
    /// `is mapping` arguments branch, the `role: tool` response branch,
    /// and the string-vs-content-parts dispatch.
    private let gemmaStyleTemplate = """
        {%- macro format_parameters(properties, required) -%}
            {%- for key, value in properties | dictsort -%}
                {{ key }}:{
                {%- if value['description'] -%}description:<|"|>{{ value['description'] }}<|"|>,{%- endif -%}
                {%- if value['type'] | upper == 'STRING' and value['enum'] -%}enum:[{%- for e in value['enum'] -%}<|"|>{{ e }}<|"|>{%- if not loop.last -%},{%- endif -%}{%- endfor -%}],{%- endif -%}
                {%- if value['type'] | upper == 'ARRAY' and value['items'] is mapping -%}items:{type:<|"|>{{ value['items']['type'] | upper }}<|"|>},{%- endif -%}
                {%- if value['nullable'] -%}nullable:true,{%- endif -%}
                {%- if value['type'] | upper == 'OBJECT' and value['properties'] is mapping -%}
                    properties:{ {{- format_parameters(value['properties'], value['required'] | default([])) -}} },
                {%- endif -%}
                type:<|"|>{{ value['type'] | upper }}<|"|>}
                {%- if not loop.last -%},{%- endif -%}
            {%- endfor -%}
        {%- endmacro -%}
        {{- bos_token -}}
        {%- set loop_messages = messages -%}
        {%- if tools or messages[0]['role'] == 'system' -%}
            {{- '<|turn>system\\n' -}}
            {%- if messages[0]['role'] == 'system' -%}
                {{- messages[0]['content'] | trim -}}
                {%- set loop_messages = messages[1:] -%}
            {%- endif -%}
            {%- for tool in tools | default([]) -%}
                {{- '<|tool>declaration:' + tool['function']['name'] + '{description:<|"|>' + tool['function']['description'] + '<|"|>,parameters:{properties:{' -}}
                {{- format_parameters(tool['function']['parameters']['properties'], tool['function']['parameters']['required'] | default([])) -}}
                {{- '},type:<|"|>' + (tool['function']['parameters']['type'] | upper) + '<|"|>}}<tool|>' -}}
            {%- endfor -%}
            {{- '<turn|>\\n' -}}
        {%- endif -%}
        {%- for message in loop_messages -%}
            {%- if message['role'] != 'tool' -%}
                {%- set role = 'model' if message['role'] == 'assistant' else message['role'] -%}
                {{- '<|turn>' + role + '\\n' -}}
                {%- if message['tool_calls'] -%}
                    {%- for tool_call in message['tool_calls'] -%}
                        {{- '<|tool_call>call:' + tool_call['function']['name'] + '{' -}}
                        {%- if tool_call['function']['arguments'] is mapping -%}
                            {%- for key, value in tool_call['function']['arguments'] | dictsort -%}
                                {{- key + ':' + value -}}{%- if not loop.last -%},{%- endif -%}
                            {%- endfor -%}
                        {%- endif -%}
                        {{- '}<tool_call|>' -}}
                    {%- endfor -%}
                {%- endif -%}
                {%- if message['content'] is string -%}
                    {{- message['content'] | trim -}}
                {%- elif message['content'] is sequence -%}
                    {%- for item in message['content'] -%}
                        {%- if item['type'] == 'text' -%}{{- item['text'] | trim -}}
                        {%- elif item['type'] == 'image' -%}{{- '<|image|>' -}}
                        {%- elif item['type'] == 'video' -%}{{- '<|video|>' -}}
                        {%- endif -%}
                    {%- endfor -%}
                {%- endif -%}
                {{- '<turn|>\\n' -}}
            {%- else -%}
                {{- '<|tool_response>response:' + (message['name'] | default('unknown')) + '{' + message['content'] + '}<tool_response|>' -}}
            {%- endif -%}
        {%- endfor -%}
        {%- if add_generation_prompt -%}{{- '<|turn>model\\n' -}}{%- endif -%}
        """

    /// The incident-class template: unconditionally indexes a key that is
    /// legitimately absent from canonical tool declarations
    /// (`function.response` — an optional Gemma extension no OpenAI request
    /// carries) and applies `| upper` to it. Renders fine for non-tool
    /// fixtures (the `tools` guard short-circuits) and throws on the tool
    /// fixture — exactly the "crashes at request time on a legitimate
    /// request shape" class DAR-130 belonged to.
    private let incidentClassTemplate = """
        {%- if tools -%}
            {%- for tool in tools -%}
                {{ tool['function']['response']['type'] | upper }}
            {%- endfor -%}
        {%- endif -%}
        {%- for message in messages -%}
            {%- if message['content'] is string -%}{{ message['role'] }}: {{ message['content'] }}
            {%- endif -%}
        {%- endfor -%}
        """

    /// ChatML-style text-only template. Note swift-jinja's `+` coerces
    /// non-strings, so this renders even for content-parts arrays — used
    /// here as a healthy template for source-collection tests.
    private let chatMLTemplate = """
        {%- for message in messages -%}
        {{ '<|im_start|>' + message['role'] + '\\n' + message['content'] + '<|im_end|>\\n' }}
        {%- endfor -%}
        {%- if add_generation_prompt -%}{{ '<|im_start|>assistant\\n' }}{%- endif -%}
        """

    /// Text-only template calling the string method `.strip()` on content —
    /// a common real-world pattern (Llama/Mistral-family templates). String
    /// method calls throw on content-parts arrays ("Cannot call
    /// non-function value"), which the runtime only ever sends to vision
    /// models.
    private let stripMethodTemplate = """
        {%- for message in messages -%}
        <|{{ message['role'] }}|>{{ message['content'].strip() }}
        {%- endfor -%}
        {%- if add_generation_prompt -%}<|assistant|>{%- endif -%}
        """

    private let visionConfigJSON = """
        {"model_type": "gemma3", "vision_config": {"hidden_size": 1152}}
        """

    private let textConfigJSON = """
        {"model_type": "qwen3"}
        """

    // MARK: - Helpers

    private func makeSnapshotDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-render-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func write(_ contents: String, to dir: URL, as name: String) throws {
        try Data(contents.utf8).write(to: dir.appendingPathComponent(name))
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - (i) Correct gemma-style template renders → true

    func testGemmaStyleTemplateRendersTrue() throws {
        let dir = try makeSnapshotDir()
        try write(gemmaStyleTemplate, to: dir, as: "chat_template.jinja")
        try write(visionConfigJSON, to: dir, as: "config.json")

        XCTAssertEqual(TemplateRenderCheck.renderOK(at: dir), true)
    }

    func testGemmaStyleTemplateScanCost() throws {
        // Informational guard: the check runs in the startup scan for every
        // cached model, so a single model's full fixture sweep (compile +
        // 5 fixture renders for a vision model) must stay well under 100ms.
        let dir = try makeSnapshotDir()
        try write(gemmaStyleTemplate, to: dir, as: "chat_template.jinja")
        try write(visionConfigJSON, to: dir, as: "config.json")

        let start = Date()
        XCTAssertEqual(TemplateRenderCheck.renderOK(at: dir), true)
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        XCTAssertLessThan(elapsedMs, 250, "render check took \(elapsedMs)ms for one model")
    }

    // MARK: - (ii) Incident-class template → false

    func testIncidentClassTemplateFailsOnToolFixture() throws {
        // The template renders plain chats fine and throws only while
        // declaring tools — proving the TOOL fixture is what catches the
        // incident class, not a generally-broken template.
        let dir = try makeSnapshotDir()
        try write(incidentClassTemplate, to: dir, as: "chat_template.jinja")
        try write(textConfigJSON, to: dir, as: "config.json")

        XCTAssertEqual(TemplateRenderCheck.renderOK(at: dir), false)
    }

    func testTemplateThatDoesNotCompileIsFalse() throws {
        let dir = try makeSnapshotDir()
        try write("{% for m in messages %}{{ m['role'] }}", to: dir, as: "chat_template.jinja")

        XCTAssertEqual(TemplateRenderCheck.renderOK(at: dir), false)
    }

    // MARK: - (iii) No template → nil (unknown), never false

    func testNoTemplateFilesReturnsNil() throws {
        let dir = try makeSnapshotDir()
        try write(textConfigJSON, to: dir, as: "config.json")
        // tokenizer_config without a chat_template key is still "no template".
        try write(#"{"bos_token": "<bos>"}"#, to: dir, as: "tokenizer_config.json")

        XCTAssertNil(TemplateRenderCheck.renderOK(at: dir))
        XCTAssertEqual(TemplateRenderCheck.templateSources(at: dir), [])
    }

    func testMissingDirectoryReturnsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        XCTAssertNil(TemplateRenderCheck.renderOK(at: missing))
    }

    // MARK: - (iv) tokenizer_config list-form templates

    func testTokenizerConfigListFormCollectsAllTemplates() throws {
        let dir = try makeSnapshotDir()
        let config = try jsonString([
            "bos_token": "<bos>",
            "chat_template": [
                ["name": "default", "template": chatMLTemplate],
                ["name": "tool_use", "template": gemmaStyleTemplate],
            ],
        ])
        try write(config, to: dir, as: "tokenizer_config.json")
        try write(textConfigJSON, to: dir, as: "config.json")

        let sources = TemplateRenderCheck.templateSources(at: dir)
        XCTAssertEqual(sources.count, 2)
        XCTAssertTrue(sources.contains(chatMLTemplate))
        XCTAssertTrue(sources.contains(gemmaStyleTemplate))

        // Both templates are healthy for a text-only model → true.
        XCTAssertEqual(TemplateRenderCheck.renderOK(at: dir), true)
    }

    func testTokenizerConfigListFormWithBrokenEntryIsFalse() throws {
        // The broken template hides in the named `tool_use` slot — exactly
        // where the runtime would select it for a tool-bearing request.
        let dir = try makeSnapshotDir()
        let config = try jsonString([
            "chat_template": [
                ["name": "default", "template": chatMLTemplate],
                ["name": "tool_use", "template": incidentClassTemplate],
            ]
        ])
        try write(config, to: dir, as: "tokenizer_config.json")
        try write(textConfigJSON, to: dir, as: "config.json")

        XCTAssertEqual(TemplateRenderCheck.renderOK(at: dir), false)
    }

    func testTokenizerConfigStringFormIsCollected() throws {
        let dir = try makeSnapshotDir()
        let config = try jsonString(["chat_template": chatMLTemplate])
        try write(config, to: dir, as: "tokenizer_config.json")

        XCTAssertEqual(TemplateRenderCheck.templateSources(at: dir), [chatMLTemplate])
        XCTAssertEqual(TemplateRenderCheck.renderOK(at: dir), true)
    }

    func testChatTemplateJSONIsCollected() throws {
        let dir = try makeSnapshotDir()
        let config = try jsonString(["chat_template": chatMLTemplate])
        try write(config, to: dir, as: "chat_template.json")

        XCTAssertEqual(TemplateRenderCheck.templateSources(at: dir), [chatMLTemplate])
    }

    func testAllSourcesAreCollectedJinjaFirst() throws {
        let dir = try makeSnapshotDir()
        try write(gemmaStyleTemplate, to: dir, as: "chat_template.jinja")
        try write(try jsonString(["chat_template": chatMLTemplate]), to: dir, as: "chat_template.json")
        try write(try jsonString(["chat_template": chatMLTemplate]), to: dir, as: "tokenizer_config.json")

        let sources = TemplateRenderCheck.templateSources(at: dir)
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources.first, gemmaStyleTemplate)
    }

    // MARK: - Multimodal fixtures gate on vision_config

    func testContentPartsOnlyJudgedForVisionModels() throws {
        // `.strip()` on content throws for content-parts arrays. A text-only
        // model never receives parts from the runtime → the parts fixtures
        // must not be judged → true. The same template on a vision model
        // WOULD crash real multimodal requests → false.
        let textDir = try makeSnapshotDir()
        try write(stripMethodTemplate, to: textDir, as: "chat_template.jinja")
        try write(textConfigJSON, to: textDir, as: "config.json")
        XCTAssertEqual(TemplateRenderCheck.renderOK(at: textDir), true)

        let visionDir = try makeSnapshotDir()
        try write(stripMethodTemplate, to: visionDir, as: "chat_template.jinja")
        try write(visionConfigJSON, to: visionDir, as: "config.json")
        XCTAssertEqual(TemplateRenderCheck.renderOK(at: visionDir), false)
    }

    func testGemmaStyleTemplateHandlesPartsForVisionModel() throws {
        // The gemma-style template dispatches on string vs sequence content,
        // so it stays true when the multimodal fixtures are in play.
        let dir = try makeSnapshotDir()
        try write(gemmaStyleTemplate, to: dir, as: "chat_template.jinja")
        try write(visionConfigJSON, to: dir, as: "config.json")

        XCTAssertEqual(TemplateRenderCheck.renderOK(at: dir), true)
    }

    // MARK: - Special tokens

    func testBosTokenFromTokenizerConfigIsUsed() throws {
        // A template interpolating bos_token renders with the config's
        // value; with no tokenizer_config it falls back to "".
        let dir = try makeSnapshotDir()
        try write("{{ bos_token }}ok", to: dir, as: "chat_template.jinja")
        try write(#"{"bos_token": "<bos>"}"#, to: dir, as: "tokenizer_config.json")

        XCTAssertEqual(TemplateRenderCheck.renderOK(at: dir), true)

        let bare = try makeSnapshotDir()
        try write("{{ bos_token }}ok", to: bare, as: "chat_template.jinja")
        XCTAssertEqual(TemplateRenderCheck.renderOK(at: bare), true)
    }

    func testAddedTokenDictFormBosToken() throws {
        let dir = try makeSnapshotDir()
        try write("{{ bos_token }}ok", to: dir, as: "chat_template.jinja")
        try write(
            #"{"bos_token": {"content": "<bos>", "lstrip": false}}"#,
            to: dir, as: "tokenizer_config.json")

        XCTAssertEqual(TemplateRenderCheck.renderOK(at: dir), true)
    }
}
