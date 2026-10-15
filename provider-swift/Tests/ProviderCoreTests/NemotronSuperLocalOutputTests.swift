import Foundation
import XCTest
import MLXLMServer
@testable import ProviderCore

final class NemotronSuperLocalOutputTests: XCTestCase {
    private func request(_ extra: String = "") throws -> OpenAIChatCompletionRequest {
        try ProviderLoop.decodeOpenAIRequest(Data(("{\"model\":\""
            + NemotronSuperLocalBinding.modelID + "\",\"messages\":[]" + extra + "}").utf8))
    }

    func testJSONOutputIsWithheldAndValidated() throws {
        var output = try NemotronSuperLocalOutput(request: request(
            #", "response_format":{"type":"json_object"}"#), nativePrefix: "")
        try output.append("{\"ok\":")
        try output.append("true}")
        let result = try output.finish()
        XCTAssertEqual(result.content, "{\"ok\":true}")
        XCTAssertTrue(result.calls.isEmpty)
        XCTAssertThrowsError(try output.finish())
    }

    func testInvalidJSONAndByteLimitFailClosed() throws {
        var output = try NemotronSuperLocalOutput(request: request(
            #", "response_format":{"type":"json_object"}"#), nativePrefix: "")
        try output.append("not json")
        XCTAssertThrowsError(try output.finish())
        var bounded = try NemotronSuperLocalOutput(request: request(), nativePrefix: "", maximumBytes: 2)
        XCTAssertThrowsError(try bounded.append("abc"))
        XCTAssertThrowsError(try bounded.finish())
    }

    func testRequiredToolCannotFinishWithoutCall() throws {
        var output = try NemotronSuperLocalOutput(request: request(
            #", "tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object","properties":{}}}}], "tool_choice":"required""#), nativePrefix: "")
        XCTAssertThrowsError(try output.finish())
    }

    func testCollectorRejectsTruncationAndMissingTerminal() async throws {
        let missing = NemotronSuperOutputCollector(try .init(request: request(), nativePrefix: ""))
        await missing.accept(.chunk("partial"))
        do { _ = try await missing.finish(); XCTFail("missing terminal accepted") } catch {}
        let truncated = NemotronSuperOutputCollector(try .init(request: request(), nativePrefix: ""))
        await truncated.accept(.chunk("partial"))
        await truncated.accept(.info(promptTokens: 1, completionTokens: 1,
            tokensPerSecond: 0, finishReason: "length"))
        do { _ = try await truncated.finish(); XCTFail("truncated output accepted") } catch {}
    }

    func testValidToolAndSchemaMismatch() throws {
        let suffix = #", "tools":[{"type":"function","function":{"name":"lookup","parameters":{"type":"object","properties":{"key":{"type":"string"}},"required":["key"]}}}], "tool_choice":"required""#
        var valid = try NemotronSuperLocalOutput(request: request(suffix), nativePrefix: "")
        try valid.append("<tool_call><function=lookup><parameter=key>value</parameter></function></tool_call>")
        XCTAssertEqual(try valid.finish().calls.count, 1)
        var invalid = try NemotronSuperLocalOutput(request: request(suffix), nativePrefix: "")
        try invalid.append("<tool_call><function=lookup></function></tool_call>")
        XCTAssertThrowsError(try invalid.finish())
    }
}
