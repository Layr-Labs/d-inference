import XCTest

import Jinja

@testable import ProviderCoreFoundation

/// Drive the REAL Jinja value bridge (`Value(any:)`) and a real
/// template render to prove (1) the un-normalized null-bearing value trees
/// throw exactly as they did at request time, and (2) `sanitizeForJinja`
/// makes them convert and render. Complements the builder-level coverage in
/// `ProviderCoreTests/JinjaSanitizationTests.swift`.
final class JinjaSanitizationRenderTests: XCTestCase {

    // MARK: - Direct bridge: throws before, converts after

    func testValueAnyThrowsOnNSNullLeafButConvertsAfterSanitize() throws {
        // Mirrors an assistant tool call whose decoded `arguments` carry a
        // JSON `null` (`{"city":"SF","unit":null}` → NSNull).
        let nullBearing: [String: Any] = [
            "role": "assistant",
            "content": "",
            "tool_calls": [
                [
                    "function": [
                        "name": "get_weather",
                        "arguments": ["city": "SF", "unit": NSNull()] as [String: Any],
                    ] as [String: Any]
                ] as [String: Any]
            ] as [[String: Any]],
        ]

        // Reproduce the incident: the raw tree hits the bridge's `default`
        // branch and throws "Cannot convert value of type … to Jinja Value".
        XCTAssertThrowsError(try Value(any: nullBearing)) { error in
            XCTAssertTrue(
                "\(error)".contains("Cannot convert value of type"),
                "unexpected error: \(error)")
        }

        // After sanitization the same logical message converts cleanly.
        XCTAssertNoThrow(try Value(any: sanitizeForJinja(nullBearing)))
    }

    func testValueAnyThrowsOnNullEnumElementButConvertsAfterSanitize() throws {
        // Mirrors a tool parameter schema with a null enum element + default.
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "unit": [
                    "type": "string",
                    "enum": ["celsius", "fahrenheit", NSNull()] as [Any],
                    "default": NSNull(),
                ] as [String: Any]
            ] as [String: Any],
        ]

        XCTAssertThrowsError(try Value(any: schema))
        XCTAssertNoThrow(try Value(any: sanitizeForJinja(schema)))
    }

    // MARK: - Scan-time self-check renders the null fixtures

    /// A template that actively dereferences the null-prone fields — the
    /// tool-call `arguments` mapping and the parameter `enum` list — so that
    /// a residual null would surface either at context build (`Value(any:)`)
    /// or during iteration. With the sanitizer in place it renders cleanly.
    private let nullProbingTemplate = """
        {%- for tool in tools | default([]) -%}
            {%- for key, value in tool['function']['parameters']['properties'] | dictsort -%}
                {{- key -}}
                {%- if value['enum'] -%}{%- for e in value['enum'] -%}{{ e }}{%- endfor -%}{%- endif -%}
            {%- endfor -%}
        {%- endfor -%}
        {%- for message in messages -%}
            {{- message['role'] -}}
            {%- for tc in message['tool_calls'] | default([]) -%}
                {%- if tc['function']['arguments'] is mapping -%}
                    {%- for key, value in tc['function']['arguments'] | dictsort -%}{{ key }}:{{ value }}{%- endfor -%}
                {%- endif -%}
            {%- endfor -%}
        {%- endfor -%}
        """

    func testRenderOKTrueForNullBearingFixturesWithProbingTemplate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jinja-null-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        try Data(nullProbingTemplate.utf8).write(to: dir.appendingPathComponent("chat_template.jinja"))
        try Data(#"{"model_type": "qwen3"}"#.utf8).write(to: dir.appendingPathComponent("config.json"))

        // The canonical fixture set now includes `tool_flow_with_nulls`; this
        // template reads the very fields that carried the nulls, so a true
        // result proves the sanitizer ran across every fixture.
        XCTAssertEqual(TemplateRenderCheck.renderOK(at: dir), true)
    }

    func testCanonicalFixturesIncludeNullBearingToolFlow() {
        let names = TemplateRenderCheck.canonicalFixtures(includeMultimodal: false).map(\.name)
        XCTAssertTrue(names.contains("tool_flow_with_nulls"))
    }
}
