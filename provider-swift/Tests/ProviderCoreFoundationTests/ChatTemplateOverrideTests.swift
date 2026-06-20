import Crypto
import Foundation
import XCTest

import Jinja

@testable import ProviderCoreFoundation

/// DAR-329: the hash-gated, non-mutating Gemma 4 chat-template override.
///
/// Proves (1) the vendored corrected template is byte-exact the verified
/// upstream file, (2) the override fires ONLY for the exact known-broken
/// revision (surgical), and (3) the corrected template renders — in the SAME
/// swift-jinja engine the runtime uses — every shape the outdated template
/// 500s on (union / typeless / response / null tool-schema fields), while
/// staying byte-identical for healthy inputs.
final class ChatTemplateOverrideTests: XCTestCase {

    private func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Provenance / pinned hashes

    func testCorrectedTemplateIsByteExactUpstream() {
        // The embedded template must be the exact upstream (lmstudio) file so
        // we can trust it renders as upstream intends.
        XCTAssertEqual(
            sha256Hex(GemmaToolTemplate.correctedToolTemplate),
            GemmaToolTemplate.correctedSHA256)
        XCTAssertEqual(
            GemmaToolTemplate.correctedSHA256,
            "29af862bccabb14b90a4ff951bcd14c33fe74b651c5f07fc7f2e9aa46a59fe7c")
    }

    func testBrokenHashIsPinnedToServedGemmaRevision() {
        XCTAssertEqual(
            GemmaToolTemplate.brokenSHA256,
            "94899c0f917d93f6fe81c95744d1e8ddab2d21d39228d2e4aec1fb2a25bff413")
    }

    func testCorrectedTemplateCarriesTheUpstreamGuards() {
        // Sanity: the corrected template is the guarded revision (macro +
        // null-guards), not the old unguarded one.
        let t = GemmaToolTemplate.correctedToolTemplate
        XCTAssertTrue(t.contains("format_type_argument"))
        XCTAssertFalse(t.contains("value['type'] | upper"))
    }

    // MARK: - Policy

    func testReplacementsMapBrokenToCorrected() {
        XCTAssertEqual(
            ChatTemplateOverride.replacements[GemmaToolTemplate.brokenSHA256],
            GemmaToolTemplate.correctedToolTemplate)
    }

    func testHealthyTemplateIsNotOverridden() {
        // An arbitrary, unrelated template must pass through untouched.
        XCTAssertNil(ChatTemplateOverride.corrected(forTemplate: "{{ messages[0]['content'] }}"))
        // And the corrected template itself is not a known-broken revision.
        XCTAssertNil(
            ChatTemplateOverride.corrected(forTemplate: GemmaToolTemplate.correctedToolTemplate))
    }

    // MARK: - Mechanism (hash match), via injected maps

    func testOverrideMatchesByContentHash() {
        let map = [sha256Hex("BROKEN-A"): "FIXED-A", sha256Hex("BROKEN-B"): "FIXED-B"]
        XCTAssertEqual(ChatTemplateOverride.corrected(forTemplate: "BROKEN-A", using: map), "FIXED-A")
        XCTAssertEqual(ChatTemplateOverride.corrected(forTemplate: "BROKEN-B", using: map), "FIXED-B")
        XCTAssertNil(ChatTemplateOverride.corrected(forTemplate: "HEALTHY", using: map))
        XCTAssertNil(ChatTemplateOverride.corrected(forTemplate: "BROKEN-A", using: [:]))
    }

    func testCorrectedTemplateForSnapshotDirReadsAndMatches() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let onDisk = "SOME-BROKEN-TEMPLATE\n"
        try Data(onDisk.utf8).write(to: dir.appendingPathComponent("chat_template.jinja"))
        let map = [sha256Hex(onDisk): "CORRECTED"]

        XCTAssertEqual(ChatTemplateOverride.correctedTemplate(forSnapshotDir: dir, using: map), "CORRECTED")
        // Missing file → nil (no crash).
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("cto-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: empty) }
        XCTAssertNil(ChatTemplateOverride.correctedTemplate(forSnapshotDir: empty, using: map))
    }

    // MARK: - Real render: corrected template handles the crashing shapes

    private func render(_ source: String, tools: [[String: Any]]?, messages: [[String: Any]]) throws -> String {
        let template = try Template(source, with: .init(lstripBlocks: true, trimBlocks: true))
        var ctx: [String: Value] = [
            "bos_token": .string(""),
            "eos_token": .string(""),
            "add_generation_prompt": .boolean(true),
            "messages": try Value(any: messages.map { sanitizeForJinja($0) }),
        ]
        if let tools {
            ctx["tools"] = try Value(any: tools.map { sanitizeForJinja($0) })
        }
        return try template.render(ctx)
    }

    private let userMsg: [[String: Any]] = [["role": "user", "content": "hi"]]

    private func tool(params: [String: Any], response: [String: Any]? = nil) -> [String: Any] {
        var fn: [String: Any] = ["name": "f", "description": "d", "parameters": params]
        if let response { fn["response"] = response }
        return ["type": "function", "function": fn]
    }

    func testCorrectedTemplateRendersHealthyTool() throws {
        let params: [String: Any] = [
            "type": "object",
            "properties": [
                "a": ["type": "string", "enum": ["x", "y"], "description": "s"] as [String: Any],
                "b": ["type": "array", "items": ["type": "integer"] as [String: Any]] as [String: Any],
            ] as [String: Any],
            "required": ["a"],
        ]
        XCTAssertNoThrow(try render(GemmaToolTemplate.correctedToolTemplate, tools: [tool(params: params)], messages: userMsg))
    }

    func testCorrectedTemplateRendersUnionTypeProperty() throws {
        // `"type": ["string","null"]` — the unguarded `| upper` 500s on this.
        let params: [String: Any] = [
            "type": "object",
            "properties": ["a": ["type": ["string", "null"] as [Any], "description": "u"] as [String: Any]] as [String: Any],
        ]
        XCTAssertNoThrow(try render(GemmaToolTemplate.correctedToolTemplate, tools: [tool(params: params)], messages: userMsg))
    }

    func testCorrectedTemplateRendersTypelessProperty() throws {
        let params: [String: Any] = [
            "type": "object",
            "properties": ["a": ["description": "no type"] as [String: Any]] as [String: Any],
        ]
        XCTAssertNoThrow(try render(GemmaToolTemplate.correctedToolTemplate, tools: [tool(params: params)], messages: userMsg))
    }

    func testCorrectedTemplateRendersResponseSchema() throws {
        // `function.response` is NOT walked by ToolSchemaNormalization, so a
        // union/absent type here reaches the template raw — the corrected
        // template must still render it.
        let params: [String: Any] = [
            "type": "object",
            "properties": ["a": ["type": "string"] as [String: Any]] as [String: Any],
        ]
        let response: [String: Any] = ["type": ["object", "null"] as [Any], "description": "r"]
        XCTAssertNoThrow(try render(GemmaToolTemplate.correctedToolTemplate, tools: [tool(params: params, response: response)], messages: userMsg))
    }

    func testCorrectedTemplateRendersNullBearingSchemaAfterSanitize() throws {
        let params: [String: Any] = [
            "type": "object",
            "properties": [
                "unit": [
                    "type": "string",
                    "enum": ["c", "f", NSNull()] as [Any],
                    "default": NSNull(),
                ] as [String: Any]
            ] as [String: Any],
            "required": ["unit"],
        ]
        XCTAssertNoThrow(try render(GemmaToolTemplate.correctedToolTemplate, tools: [tool(params: params)], messages: userMsg))
    }

    func testCorrectedTemplateRendersPlainChat() throws {
        XCTAssertNoThrow(try render(GemmaToolTemplate.correctedToolTemplate, tools: nil, messages: [
            ["role": "system", "content": "be brief"],
            ["role": "user", "content": "hello"],
        ]))
    }

    // MARK: - Contrast: the unguarded pattern really does throw

    func testUnguardedUpperPatternThrowsOnUnionButCorrectedDoesNot() throws {
        // Minimal reproduction of the outdated template's failing pattern.
        let unguarded = """
            {%- for tool in tools -%}
            {%- for k, v in tool['function']['parameters']['properties'] | dictsort -%}
            {{ v['type'] | upper }}
            {%- endfor -%}
            {%- endfor -%}
            """
        let unionTool = tool(params: [
            "type": "object",
            "properties": ["a": ["type": ["string", "null"] as [Any]] as [String: Any]] as [String: Any],
        ])
        XCTAssertThrowsError(try render(unguarded, tools: [unionTool], messages: userMsg)) { error in
            XCTAssertTrue("\(error)".contains("upper filter requires string"), "unexpected: \(error)")
        }
        // The corrected template handles the very same input.
        XCTAssertNoThrow(try render(GemmaToolTemplate.correctedToolTemplate, tools: [unionTool], messages: userMsg))
    }

    // MARK: - renderOK integration (corrected template advertises render_ok)

    func testRenderOKTrueForCorrectedTemplateOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cto-ok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try Data(GemmaToolTemplate.correctedToolTemplate.utf8)
            .write(to: dir.appendingPathComponent("chat_template.jinja"))
        try Data(#"{"model_type": "gemma3"}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        XCTAssertEqual(TemplateRenderCheck.renderOK(at: dir), true)
    }
}
