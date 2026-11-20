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

    private func tools(nesting levels: Int) -> [[String: Any]] {
        var schema: [String: Any] = ["type": "string"]
        for _ in 0..<levels { schema = ["type": "array", "items": schema] }
        return [[
            "type": "function",
            "function": [
                "name": "probe",
                "parameters": ["type": "object", "properties": ["a": schema]] as [String: Any],
            ] as [String: Any],
        ]]
    }

    private func expected(nesting levels: Int) -> String {
        String(repeating: "array<", count: levels) + "string" + String(repeating: ">", count: levels)
    }

    /// `body`'s result from a thread with a request-sized stack.
    private func onRequestStack<Value>(_ body: @escaping @Sendable () -> Value) -> Value where Value: Sendable {
        let box = ResultBox<Value>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.stackSize = Self.requestStackBytes
        thread.start()
        done.wait()
        return box.value!
    }

    private final class ResultBox<Value>: @unchecked Sendable { var value: Value? }

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
}
