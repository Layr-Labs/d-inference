import CryptoKit
import Foundation
import Jinja
import Testing

@testable import ProviderCore

/// Render-level E1 regression against the SERVED Gemma chat template
/// (`gemma-4-26b-qat-4bit` @ 2026-06-08-r1, byte-identical to
/// mlx-community/gemma-4-26b-a4b-it-qat-4bit, template sha256 94899c0f…).
///
/// The fixture embeds the template's `format_parameters`,
/// `format_function_declaration`, and `format_argument` macros VERBATIM (the
/// declaration macro calls the other two), followed by the template's own
/// tool-declaration driver loop (served lines 196–203). Each crash-corpus
/// case is proven BOTH ways against the real Jinja engine:
///
///   • un-normalized (null-sanitize only — exactly what reached the template
///     before this fix when a caller bypassed the shared normalizers): the
///     render THROWS (the production `jinja_template` 500, live error text
///     "upper filter requires string");
///   • after `ChatTemplateFixes.normalizeTools` with a gemma4 context (the
///     production chokepoint: shared normalization + Gemma4 enforcement):
///     the render succeeds.
@Suite("Gemma4 served-template render regression (E1)")
struct Gemma4ServedTemplateRenderTests {

    /// Served macros, verbatim (do NOT reformat — byte-exactness is the point).
    private static let servedMacros = #"""
{%- macro format_parameters(properties, required, filter_keys=false) -%}
    {%- set standard_keys = ['description', 'type', 'properties', 'required', 'nullable'] -%}
    {%- set ns = namespace(found_first=false) -%}
    {%- for key, value in properties | dictsort -%}
        {%- set add_comma = false -%}
        {%- if not filter_keys or key not in standard_keys -%}
            {%- if ns.found_first %},{% endif -%}
            {%- set ns.found_first = true -%}
            {{ key }}:{
            {%- if value['description'] -%}
                description:<|"|>{{ value['description'] }}<|"|>
                {%- set add_comma = true -%}
            {%- endif -%}
            {%- if value['type'] | upper == 'STRING' -%}
                {%- if value['enum'] -%}
                    {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
                    enum:{{ format_argument(value['enum']) }}
                {%- endif -%}
            {%- elif value['type'] | upper == 'ARRAY' -%}
                {%- if value['items'] is mapping and value['items'] -%}
                    {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
                    items:{
                    {%- set ns_items = namespace(found_first=false) -%}
                    {%- for item_key, item_value in value['items'] | dictsort -%}
                        {%- if item_value is not none -%}
                            {%- if ns_items.found_first %},{% endif -%}
                            {%- set ns_items.found_first = true -%}
                            {%- if item_key == 'properties' -%}
                                properties:{
                                {%- if item_value is mapping -%}
                                    {{- format_parameters(item_value, value['items']['required'] | default([])) -}}
                                {%- endif -%}
                                }
                            {%- elif item_key == 'required' -%}
                                required:[
                                {%- for req_item in item_value -%}
                                    <|"|>{{- req_item -}}<|"|>
                                    {%- if not loop.last %},{% endif -%}
                                {%- endfor -%}
                                ]
                            {%- elif item_key == 'type' -%}
                                {%- if item_value is string -%}
                                    type:{{ format_argument(item_value | upper) }}
                                {%- else -%}
                                    type:{{ format_argument(item_value | map('upper') | list) }}
                                {%- endif -%}
                            {%- else -%}
                                {{ item_key }}:{{ format_argument(item_value) }}
                            {%- endif -%}
                        {%- endif -%}
                    {%- endfor -%}
                    }
                {%- endif -%}
            {%- endif -%}
            {%- if value['nullable'] %}
                {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
                nullable:true
            {%- endif -%}
            {%- if value['type'] | upper == 'OBJECT' -%}
                {%- if value['properties'] is defined and value['properties'] is mapping -%}
                    {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
                    properties:{
                    {{- format_parameters(value['properties'], value['required'] | default([])) -}}
                    }
                {%- elif value is mapping -%}
                    {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
                    properties:{
                    {{- format_parameters(value, value['required'] | default([]), filter_keys=true) -}}
                    }
                {%- endif -%}
                {%- if value['required'] -%}
                    {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
                    required:[
                    {%- for item in value['required'] | default([]) -%}
                        <|"|>{{- item -}}<|"|>
                        {%- if not loop.last %},{% endif -%}
                    {%- endfor -%}
                    ]
                {%- endif -%}
            {%- endif -%}
            {%- if add_comma %},{%- else -%} {%- set add_comma = true -%} {% endif -%}
            type:<|"|>{{ value['type'] | upper }}<|"|>}
        {%- endif -%}
    {%- endfor -%}
{%- endmacro -%}
{%- macro format_function_declaration(tool_data) -%}
    declaration:{{- tool_data['function']['name'] -}}{description:<|"|>{{- tool_data['function']['description'] -}}<|"|>
    {%- set params = tool_data['function']['parameters'] -%}
    {%- if params -%}
        ,parameters:{
        {%- if params['properties'] -%}
            properties:{ {{- format_parameters(params['properties'], params['required']) -}} },
        {%- endif -%}
        {%- if params['required'] -%}
            required:[
            {%- for item in params['required'] -%}
                <|"|>{{- item -}}<|"|>
                {{- ',' if not loop.last -}}
            {%- endfor -%}
            ],
        {%- endif -%}
        {%- if params['type'] -%}
            type:<|"|>{{- params['type'] | upper -}}<|"|>}
        {%- endif -%}
    {%- endif -%}
    {%- if 'response' in tool_data['function'] -%}
        {%- set response_declaration = tool_data['function']['response'] -%}
        ,response:{
        {%- if response_declaration['description'] -%}
            description:<|"|>{{- response_declaration['description'] -}}<|"|>,
        {%- endif -%}
        {%- if response_declaration['type'] | upper == 'OBJECT' -%}
            type:<|"|>{{- response_declaration['type'] | upper -}}<|"|>}
        {%- endif -%}
    {%- endif -%}
    }
{%- endmacro -%}
{%- macro format_argument(argument, escape_keys=True) -%}
    {%- if argument is string -%}
        {{- '<|"|>' + argument + '<|"|>' -}}
    {%- elif argument is boolean -%}
        {{- 'true' if argument else 'false' -}}
    {%- elif argument is mapping -%}
        {{- '{' -}}
        {%- set ns = namespace(found_first=false) -%}
        {%- for key, value in argument | dictsort -%}
            {%- if ns.found_first %},{% endif -%}
            {%- set ns.found_first = true -%}
            {%- if escape_keys -%}
                {{- '<|"|>' + key + '<|"|>' -}}
            {%- else -%}
                {{- key -}}
            {%- endif -%}
            :{{- format_argument(value, escape_keys=escape_keys) -}}
        {%- endfor -%}
        {{- '}' -}}
    {%- elif argument is sequence -%}
        {{- '[' -}}
        {%- for item in argument -%}
            {{- format_argument(item, escape_keys=escape_keys) -}}
            {%- if not loop.last %},{% endif -%}
        {%- endfor -%}
        {{- ']' -}}
    {%- else -%}
        {{- argument -}}
    {%- endif -%}
{%- endmacro -%}

"""#

    /// The served template's tool-declaration driver (lines 196–203).
    private static let toolDeclarationDriver = #"""
    {%- if tools -%}
        {%- for tool in tools %}
            {{- '<|tool>' -}}
            {{- format_function_declaration(tool) | trim -}}
            {{- '<tool|>' -}}
        {%- endfor %}
    {%- endif -%}
    """#

    private static let fixtureSource = servedMacros + "\n" + toolDeclarationDriver

    private let gemmaContext = ChatTemplateFixContext(
        modelId: "gemma-4-26b-a4b-it-qat-4bit", modelType: "gemma4_text")

    private func tool(parameters: [String: any Sendable]) -> [String: any Sendable] {
        [
            "type": "function",
            "function": [
                "name": "probe", "description": "corpus probe",
                "parameters": parameters,
            ] as [String: any Sendable],
        ]
    }

    /// Render the fixture with the same compile options as the runtime
    /// tokenizer (swift-transformers `compiledTemplate(for:)`).
    private func render(tools: [[String: any Sendable]]) throws -> String {
        let template = try Template(
            Self.fixtureSource, with: .init(lstripBlocks: true, trimBlocks: true))
        let context: [String: Value] = [
            "tools": .array(try tools.map { try Value(any: $0) })
        ]
        return try template.render(context)
    }

    /// The pre-fix pipeline: null-sanitize only (what `sanitizeTools` did
    /// before the Gemma enforcement existed).
    private func renderUnnormalized(_ parameters: [String: any Sendable]) throws -> String {
        let sanitized = ChatTemplateFixes.sanitizeTools([tool(parameters: parameters)]) ?? []
        return try render(tools: sanitized)
    }

    /// The production pipeline for gemma4.
    private func renderNormalized(_ parameters: [String: any Sendable]) throws -> String {
        let normalized =
            ChatTemplateFixes.normalizeTools(
                [tool(parameters: parameters)], context: gemmaContext) ?? []
        return try render(tools: normalized)
    }

    /// E1 crash corpus: every case is a VALID request shape whose raw render
    /// throws in the served macros.
    private static let crashCorpus: [(name: String, parameters: [String: any Sendable])] = [
        (
            "empty property schema",
            ["type": "object", "properties": ["x": [String: any Sendable]()] as [String: any Sendable]]
        ),
        (
            "const-only property",
            ["type": "object", "properties": ["c": ["const": "v"] as [String: any Sendable]] as [String: any Sendable]]
        ),
        (
            "default-only property",
            ["type": "object", "properties": ["d": ["default": 5] as [String: any Sendable]] as [String: any Sendable]]
        ),
        (
            "$ref-only property",
            ["type": "object", "properties": ["r": ["$ref": "#/$defs/x"] as [String: any Sendable]] as [String: any Sendable]]
        ),
        (
            "format-only property",
            ["type": "object", "properties": ["f": ["format": "date-time"] as [String: any Sendable]] as [String: any Sendable]]
        ),
        (
            "boolean true schema",
            ["type": "object", "properties": ["b": true] as [String: any Sendable]]
        ),
        (
            "boolean false schema",
            ["type": "object", "properties": ["bf": false] as [String: any Sendable]]
        ),
        (
            "scalar non-string type",
            ["type": "object", "properties": ["n": ["type": 123] as [String: any Sendable]] as [String: any Sendable]]
        ),
        (
            "patternProperties without properties",
            [
                "type": "object",
                "properties": [
                    "env": [
                        "type": "object",
                        "patternProperties": ["^E_": ["type": "string"] as [String: any Sendable]]
                            as [String: any Sendable],
                    ] as [String: any Sendable]
                ] as [String: any Sendable],
            ]
        ),
        (
            "prefixItems-only property",
            [
                "type": "object",
                "properties": [
                    "pair": ["prefixItems": [["type": "string"] as [String: any Sendable]] as [any Sendable]]
                        as [String: any Sendable]
                ] as [String: any Sendable],
            ]
        ),
        (
            "scalar property value",
            ["type": "object", "properties": ["s": 5] as [String: any Sendable]]
        ),
        (
            "object node with junk keys",
            [
                "type": "object",
                "properties": [
                    "cfg": ["type": "object", "minProperties": 1] as [String: any Sendable]
                ] as [String: any Sendable],
            ]
        ),
    ]

    @Test func corpusThrowsWithoutNormalization() {
        for (name, parameters) in Self.crashCorpus {
            #expect(throws: (any Error).self, "\(name) must throw un-normalized") {
                _ = try renderUnnormalized(parameters)
            }
        }
    }

    @Test func corpusRendersAfterNormalization() throws {
        for (name, parameters) in Self.crashCorpus {
            let rendered = try renderNormalized(parameters)
            #expect(rendered.contains("<|tool>declaration:probe"), "\(name): \(rendered)")
            #expect(rendered.contains("<tool|>"), "\(name): \(rendered)")
        }
    }

    /// Every property value the corpus normalizes must render an upper-cased
    /// string type — the exact expression that crashed in production.
    @Test func normalizedBooleanSchemaRendersStringType() throws {
        let rendered = try renderNormalized(
            ["type": "object", "properties": ["b": true] as [String: any Sendable]])
        // The served macro emits a space before `type` when no other keys
        // rendered (its add_comma else-branch) — asserted as-rendered.
        #expect(rendered.contains(#"b:{ type:<|"|>STRING<|"|>}"#))
    }

    /// Control: a fully-typed, well-formed spec renders WITHOUT any
    /// normalization — the fixture itself is healthy; the corpus failures
    /// above are the request shapes, not a broken fixture.
    @Test func wellFormedSpecRendersUnnormalized() throws {
        let rendered = try renderUnnormalized([
            "type": "object",
            "properties": [
                "city": ["type": "string", "description": "c"] as [String: any Sendable]
            ] as [String: any Sendable],
            "required": ["city"],
        ])
        #expect(rendered.contains("declaration:probe"))
        #expect(rendered.contains(#"city:{"#))
        #expect(rendered.contains(#"type:<|"|>STRING<|"|>"#))
        #expect(rendered.contains(#"required:[<|"|>city<|"|>]"#))
    }

    /// The embedded macros must stay byte-identical to the served template:
    /// this is the sha256 of lines 1–147 (`sed -n '1,147p'`, trailing newline
    /// included) of the 94899c0f… artifact. Guards against accidental
    /// reformatting of the fixture, which would silently detach this
    /// regression test from the production artifact.
    @Test func servedMacroFixtureIsByteExact() {
        let expectedSHA256 = "a489e5fcbc51a77fd665cba6d20e924d52bde8b0a8e1712f95c8e1f8859d879d"
        #expect(sha256Hex(Self.servedMacros) == expectedSHA256)
    }

    private func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Post-push Codex P2 shape: an object property carrying ONLY
    /// `patternProperties` crashes the served macros un-normalized (the
    /// OBJECT fallback iterates the node's own keys; the patternProperties
    /// container has no `type`) and must render after the production
    /// pipeline injects the empty `properties` map.
    @Test func patternPropertiesOnlyObjectRendersAfterNormalization() throws {
        let parameters: [String: any Sendable] = [
            "type": "object",
            "properties": [
                "env": [
                    "type": "object",
                    "patternProperties":
                        ["^ENV_": ["type": "string"] as [String: any Sendable]]
                        as [String: any Sendable],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
        #expect(throws: (any Error).self, "un-normalized patternProperties-only object must throw") {
            _ = try renderUnnormalized(parameters)
        }
        _ = try renderNormalized(parameters)
    }
}
