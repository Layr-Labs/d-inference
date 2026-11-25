import CryptoKit
import XCTest

import Jinja

@testable import ProviderCore

/// A chat template that formats a tool schema with a recursive macro recurses in the Jinja interpreter once per
/// schema level, and a request renders on a 512 KiB stack. `TemplateRenderStack` gives the render a stack of its own.
final class TemplateRenderStackTests: XCTestCase {
    /// What Gemma 4's `format_parameters` does to a nested schema, reduced to the recursion.
    private static let recursiveTemplate = """
        {%- macro format_schema(schema) -%}
        {{- schema['type'] -}}
        {%- if schema['items'] is defined -%}<{{- format_schema(schema['items']) -}}>{%- endif -%}
        {%- endmacro -%}
        {{- format_schema(tools[0]['function']['parameters']['properties']['a']) -}}
        """

    /// The request-sized stack: a Swift concurrency cooperative thread's.
    private static let requestStackBytes = 512 << 10

    /// SHA-256 of GPT-OSS's served chat template (`Fixtures/GPTOSS/chat_template.jinja`).
    private static let gptossTemplateSHA256 = "a4c9919cbbd4acdd51ccffe22da049264b1b73e59055fa58811a99efbd7c8146"

    /// One tool whose parameter `a` is a string inside `levels` arrays (`items`) or objects (`properties`).
    private func tools(nesting levels: Int, keyword: String = "items") -> [[String: Any]] {
        var schema: [String: Any] = ["type": "string"]
        for _ in 0..<levels {
            schema = keyword == "items"
                ? ["type": "array", "items": schema]
                : ["type": "object", "properties": ["x": schema] as [String: Any]]
        }
        return [[
            "type": "function",
            "function": [
                "name": "probe",
                "description": "probe",
                "parameters": ["type": "object", "properties": ["a": schema]] as [String: Any],
            ] as [String: Any],
        ]]
    }

    private func expected(nesting levels: Int) -> String {
        String(repeating: "array<", count: levels) + "string" + String(repeating: ">", count: levels)
    }

    /// `body`'s result from a thread with a request-sized stack, at `qualityOfService`.
    private func onRequestStack<Value>(
        qualityOfService: QualityOfService = .default, _ body: @escaping @Sendable () -> Value
    ) -> Value where Value: Sendable {
        let box = ResultBox<Value>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.stackSize = Self.requestStackBytes
        thread.qualityOfService = qualityOfService
        thread.start()
        done.wait()
        return box.value!
    }

    private final class ResultBox<Value>: @unchecked Sendable { var value: Value? }

    /// GPT-OSS's served chat template, checked against its hash.
    private func gptossTemplateSource() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "chat_template", withExtension: "jinja", subdirectory: "Fixtures/GPTOSS"))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), Self.gptossTemplateSHA256)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    /// The deepest schema a request may carry (`JSONNestingLimit`: 64 levels) renders from a request-sized stack.
    /// Without the render stack it needs more than that stack holds in a debug build.
    func testDeepestRequestSchemaRendersFromARequestSizedStack() throws {
        let levels = 64
        let template = try Template(Self.recursiveTemplate)
        let context: [String: Value] = ["tools": try Value(any: tools(nesting: levels))]
        let rendered = onRequestStack {
            Result { try TemplateRenderStack.run { try template.render(context) } }
        }
        XCTAssertEqual(try rendered.get(), expected(nesting: levels))
    }

    func testAShallowSchemaRendersTheSameText() throws {
        let template = try Template(Self.recursiveTemplate)
        let context: [String: Value] = ["tools": try Value(any: tools(nesting: 3))]
        XCTAssertEqual(try TemplateRenderStack.run { try template.render(context) }, try template.render(context))
    }

    func testTheBodyRunsOnAThreadWithTheRenderStack() {
        let bytes = TemplateRenderStack.run { Thread.current.stackSize }
        XCTAssertEqual(bytes, TemplateRenderStack.bytes)
        XCTAssertGreaterThan(bytes, Self.requestStackBytes)
    }

    func testTheBodysErrorReachesTheCaller() {
        struct Refused: Error, Equatable {}
        XCTAssertThrowsError(try TemplateRenderStack.run { () throws -> Int in throw Refused() }) { error in
            XCTAssertTrue(error is Refused)
        }
    }

    /// The render thread runs at its caller's quality of service, the default class included.
    func testTheBodyRunsAtItsCallersQualityOfService() {
        let classes: [(QualityOfService, qos_class_t)] = [
            (.userInteractive, QOS_CLASS_USER_INTERACTIVE), (.userInitiated, QOS_CLASS_USER_INITIATED),
            (.default, QOS_CLASS_DEFAULT), (.utility, QOS_CLASS_UTILITY), (.background, QOS_CLASS_BACKGROUND),
        ]
        for (qualityOfService, qosClass) in classes {
            let (caller, render) = onRequestStack(qualityOfService: qualityOfService) {
                (qos_class_self().rawValue, TemplateRenderStack.run { qos_class_self().rawValue })
            }
            XCTAssertEqual(caller, qosClass.rawValue)
            XCTAssertEqual(render, caller)
        }
    }

    /// Renders started at once from many tasks, as concurrent requests start them: each caller waits for a render
    /// thread of its own and gets its own render's text.
    func testConcurrentRendersEachGetTheirOwnText() async throws {
        let template = try Template(Self.recursiveTemplate)
        let renders = try (33...64).map { levels -> (Int, [String: Value]) in
            (levels, ["tools": try Value(any: tools(nesting: levels))])
        }
        let rendered = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (levels, context) in renders {
                group.addTask {
                    let text = try TemplateRenderStack.run { try template.render(context) }
                    return (levels, text)
                }
            }
            var rendered: [Int: String] = [:]
            for try await (levels, text) in group { rendered[levels] = text }
            return rendered
        }
        XCTAssertEqual(rendered.count, renders.count)
        for (levels, _) in renders { XCTAssertEqual(rendered[levels], expected(nesting: levels)) }
    }

    /// GPT-OSS's served chat template, whose `render_typescript_type` macro needs the most stack per schema level of
    /// the served templates, renders the deepest schema a request may carry on the render stack in this build, as
    /// nested objects and as nested arrays.
    func testTheServedGPTOSSTemplateRendersTheDeepestRequestSchema() throws {
        let template = try Template(try gptossTemplateSource(), with: .init(lstripBlocks: true, trimBlocks: true))
        // Nested objects print every level. Nested arrays print a type that starts again from `any[]` whenever it
        // passes 50 characters: at 64 levels it is `any` and 17 `[]`.
        let arrays = "a?: any" + String(repeating: "[]", count: 17) + ","
        for (keyword, marker, count) in [("properties", "x?: ", 64), ("items", arrays, 1)] {
            let context: [String: Value] = [
                "messages": try Value(any: [["role": "user", "content": "hi"]]),
                "tools": try Value(any: tools(nesting: 64, keyword: keyword)),
                "add_generation_prompt": .boolean(true),
            ]
            let rendered = try TemplateRenderStack.run { try template.render(context) }
            XCTAssertEqual(rendered.components(separatedBy: marker).count - 1, count, keyword)
        }
    }
}
