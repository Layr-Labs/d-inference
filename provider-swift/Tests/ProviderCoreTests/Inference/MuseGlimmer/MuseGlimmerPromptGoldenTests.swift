// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Parity with `Fixtures/MuseGlimmer/prompt-golden.json`, written by
/// `scripts/muse-glimmer-qualification/prompt_golden.py` from Python Jinja2
/// with Transformers' template semantics and the pinned tokenizer.
///
/// The text check always runs: each case's OpenAI body goes through the
/// production request pipeline and the served template under the pinned
/// Swift-Jinja, and must equal the reference prompt. Token-ID parity needs the
/// real 28 MB tokenizer through `MUSE_GLIMMER_NVFP4_DIR` (that script's
/// `--model-dir`); it loads no weights.
@Suite("Muse Glimmer prompt goldens")
struct MuseGlimmerPromptGoldenTests {
    private static let modelType = MuseGlimmerModelPolicy.modelType
    /// The template the packaged artifact carries: the publisher's newer
    /// template with only its date block replaced.
    static let servedTemplateSHA256 = "6e0a14fabecc8c547bd3cbb3937128f1a97f1c95a0c645ea228b457898f926a9"
    private static let referenceDirectoryKey = "MUSE_GLIMMER_NVFP4_DIR"

    private struct Case {
        let name: String
        let category: String
        let body: Data
        let prompt: String
        let tokens: [Int]
        let strength: String?
    }

    private struct Corpus {
        let hashes: [String: String]
        let specialTokens: [String: String]
        let cases: [Case]
    }

    private static func fixture(_ name: String, _ fileExtension: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: fileExtension, subdirectory: "Fixtures/MuseGlimmer"))
        return try Data(contentsOf: url)
    }

    private static func servedTemplate() throws -> String {
        try #require(String(data: fixture("chat_template", "jinja"), encoding: .utf8))
    }

    private static func corpus() throws -> Corpus {
        let root = try #require(
            JSONSerialization.jsonObject(with: fixture("prompt-golden", "json")) as? [String: Any])
        let reference = try #require(root["reference"] as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        return Corpus(
            hashes: try #require(reference["sha256"] as? [String: String]),
            specialTokens: try #require(reference["special_tokens"] as? [String: String]),
            cases: try cases.map { entry in
                Case(name: try #require(entry["name"] as? String),
                     category: try #require(entry["category"] as? String),
                     body: try JSONSerialization.data(withJSONObject: try #require(entry["body"])),
                     prompt: try #require(entry["prompt"] as? String),
                     tokens: try #require(entry["token_ids"] as? [Int]),
                     strength: entry["reasoning_strength"] as? String)
            })
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Prepared {
        let request: OpenAIChatCompletionRequest
        let prepared: ToolChoicePromptPolicy.Prepared
        let controls: ChatTemplateControls
        let input: ProviderPromptContractPipeline.NormalizedInput
    }

    /// The production request pipeline, up to what the tokenizer receives.
    private static func prepare(_ body: Data) throws -> Prepared {
        let request = try ProviderLoop.decodeOpenAIRequest(body, modelType: modelType)
        let controls = ProviderLoop.extractChatTemplateControls(from: body).resolvingPromptDate()
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
        return Prepared(request: request, prepared: prepared, controls: controls,
            input: try ProviderPromptContractPipeline.normalizedInput(
                prepared: prepared, request: request, modelType: modelType, templateControls: controls))
    }

    /// The render the runtime tokenizer performs (`LocalTokenizerLoader`'s
    /// bridge over swift-transformers), without the tokenizer: the same
    /// template normalization, compile options, context and model filters.
    private static func render(_ body: Data, template: String, specialTokens: [String: String]) throws -> String {
        let input = try prepare(body).input
        let compiled = try Template(
            normalizeSwiftJinjaTemplate(template), with: .init(lstripBlocks: true, trimBlocks: true))
        var context: [String: Jinja.Value] = [
            "messages": .array(try input.messages.map { try Jinja.Value(any: $0) }),
            "add_generation_prompt": .boolean(true),
        ]
        if let tools = input.tools { context["tools"] = .array(try tools.map { try Jinja.Value(any: $0) }) }
        var additional = input.additionalContext ?? [:]
        additional.merge(ReferenceTemplateFilters.additionalContext(modelType: modelType) ?? [:]) { _, filter in filter }
        for (key, value) in additional { context[key] = try Jinja.Value(any: value) }
        for (key, value) in specialTokens { context[key] = .string(value) }
        return try compiled.render(context)
    }

    @Test("the corpus pins the served template")
    func corpusPinsTheServedTemplate() throws {
        let corpus = try Self.corpus()
        #expect(Self.sha256(try Self.fixture("chat_template", "jinja")) == Self.servedTemplateSHA256)
        #expect(corpus.hashes["chat_template.jinja"] == Self.servedTemplateSHA256)
        #expect(corpus.cases.count >= 30)
        #expect(Set(corpus.cases.map(\.name)).count == corpus.cases.count)
        #expect(Set(corpus.cases.map(\.category)) == ["text", "reasoning", "tools", "edge"])
    }

    @Test("the production pipeline and Swift-Jinja reproduce every reference prompt")
    func renderedPromptTextMatchesReference() throws {
        let corpus = try Self.corpus()
        let template = try Self.servedTemplate()
        for fixture in corpus.cases {
            let rendered = try Self.render(fixture.body, template: template, specialTokens: corpus.specialTokens)
            #expect(rendered == fixture.prompt, "\(fixture.name)")
            #expect(try Self.prepare(fixture.body).input.additionalContext?["reasoning_strength"] as? String
                == fixture.strength, "\(fixture.name)")
            // Every prompt ends where the model's first header begins.
            #expect(rendered.hasSuffix("<|start|>assistant"), "\(fixture.name)")
        }
    }

    /// The publisher's date block, which the served template replaces.
    private static func publishedForm(of served: String) throws -> String {
        let line = "{{- '\\nCurrent date: ' + strftime_now('%Y-%m-%d') + '.' -}}"
        try #require(served.components(separatedBy: line).count == 2)
        return served.replacingOccurrences(of: line, with: """
            {%- if current_date is defined and current_date -%}
                    {{- '\\nCurrent date: ' + current_date + '.' -}}
                {%- elif strftime_now is defined -%}
                    \(line)
                {%- endif -%}
            """)
    }

    @Test("the served template passes the date guard; the publisher's date block does not")
    func dateGuard() throws {
        let served = try Self.servedTemplate()
        #expect(PromptRenderDate.supportsTemplate(served))
        #expect(served.components(separatedBy: "strftime_now").count == 2)
        #expect(!PromptRenderDate.supportsTemplate(try Self.publishedForm(of: served)))
    }

    /// A model directory holding `template` beside minimal metadata.
    private static func directory(template: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-glimmer-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(template.utf8).write(to: directory.appendingPathComponent("chat_template.jinja"))
        try Data(#"{"model_type":"muse_glimmer"}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data(#"{"version":"1.0"}"#.utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        try Data(#"{"bos_token":"<|begin_of_text|>","eos_token":"<|end_of_text|>"}"#.utf8)
            .write(to: directory.appendingPathComponent("tokenizer_config.json"))
        return directory
    }

    @Test("the served template yields a prompt contract; the publisher's form yields none")
    func promptContract() throws {
        let served = try Self.servedTemplate()
        let servedDirectory = try Self.directory(template: served)
        let publishedDirectory = try Self.directory(template: try Self.publishedForm(of: served))
        defer {
            try? FileManager.default.removeItem(at: servedDirectory)
            try? FileManager.default.removeItem(at: publishedDirectory)
        }
        #expect(TemplateRenderCheck.renderOK(at: servedDirectory) == true)
        let contract = try PromptContractIdentity.compute(modelDirectory: servedDirectory)
        #expect(contract.utf8.count == 64)
        #expect(PrefixCachePolicy.checkpointIdentityHash(contract) == contract)
        // It renders, but nothing can cache or route on it.
        #expect(TemplateRenderCheck.renderOK(at: publishedDirectory) == true)
        #expect(throws: PromptContractIdentity.Error.invalidArtifact) {
            _ = try PromptContractIdentity.compute(modelDirectory: publishedDirectory)
        }
    }

    @Test("the template writes JSON as the reference does, for this model type only")
    func referenceJSONFilter() throws {
        let template = try Template("{{ value | tojson }}")
        let value: [String: Any?] = [
            "b": ["x/y", "漢字", "q\"uote"], "a": ["k": 1, "none": nil, "t": true, "f": 0.5]]
        func render(_ modelType: String?) throws -> String {
            var context: [String: Jinja.Value] = ["value": try Jinja.Value(any: value)]
            for (key, filter) in ReferenceTemplateFilters.additionalContext(modelType: modelType) ?? [:] {
                context[key] = try Jinja.Value(any: filter)
            }
            return try template.render(context)
        }
        // Python: json.dumps(value, ensure_ascii=False), keys as the bridge sorts them.
        #expect(try render(Self.modelType)
            == #"{"a": {"f": 0.5, "k": 1, "none": null, "t": true}, "b": ["x/y", "漢字", "q\"uote"]}"#)
        // Any other family keeps Swift-Jinja's own rendering.
        let (other, unbound, glimmer) = (try render("llama"), try render(nil), try render(Self.modelType))
        #expect(other == unbound)
        #expect(other != glimmer)
        #expect(MuseGlimmerTemplateFilters.additionalContext(modelType: "nemotron_h") == nil)
    }

    @Test("the real tokenizer reproduces the reference token IDs",
          .enabled(if: ProcessInfo.processInfo.environment[referenceDirectoryKey] != nil,
                   "set MUSE_GLIMMER_NVFP4_DIR to the pinned tokenizer directory (scripts/muse-glimmer-qualification/README.md)"))
    func realTokenizerReproducesGoldenTokenIDs() async throws {
        let source = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment[Self.referenceDirectoryKey]), isDirectory: true)
        let corpus = try Self.corpus()
        // The served artifact: the reference tokenizer beside the served template.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-glimmer-golden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            let file = source.appendingPathComponent(name)
            #expect(Self.sha256(try Data(contentsOf: file)) == corpus.hashes[name], "\(name) is not the pinned file")
            try FileManager.default.createSymbolicLink(
                at: directory.appendingPathComponent(name), withDestinationURL: file)
        }
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("config.json"),
            withDestinationURL: source.appendingPathComponent("config.json"))
        try Self.fixture("chat_template", "jinja").write(to: directory.appendingPathComponent("chat_template.jinja"))

        let tokenizer = try await LocalTokenizerLoader(environment: [:]).load(from: directory)
        for fixture in corpus.cases {
            #expect(tokenizer.encode(text: fixture.prompt, addSpecialTokens: false) == fixture.tokens,
                    "tokenizer: \(fixture.name)")
            let prepared = try Self.prepare(fixture.body)
            #expect(try ProviderPromptContractPipeline.tokenize(
                prepared: prepared.prepared, request: prepared.request, tokenizer: tokenizer,
                modelType: Self.modelType, templateControls: prepared.controls) == fixture.tokens,
                "pipeline: \(fixture.name)")
            // One beginning-of-text token, from the template alone.
            #expect(fixture.tokens.first == 200_000 && fixture.tokens.dropFirst().first != 200_000,
                    "\(fixture.name)")
        }
        let stops = MuseGlimmerTemplateFix.stopTokenIds(base: [], tokenToId: tokenizer.convertTokenToId)
        #expect(stops == [200_001, 200_008])
        #expect(tokenizer.convertTokenToId("<|eom|>") == 200_007)
    }
}
