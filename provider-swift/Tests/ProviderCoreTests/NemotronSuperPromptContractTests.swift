import Foundation
import XCTest
@testable import ProviderCore

final class NemotronSuperPromptContractTests: XCTestCase {
    func testOfficialDefaultsAndMediumEffort() throws {
        let defaults = try NemotronSuperPromptContract.additionalContext(body: Data("{}".utf8))
        XCTAssertEqual(defaults["enable_thinking"] as? Bool, true)
        XCTAssertEqual(defaults["medium_effort"] as? Bool, false)
        XCTAssertEqual(defaults["truncate_history_thinking"] as? Bool, true)
        let medium = try NemotronSuperPromptContract.additionalContext(body: Data(
            #"{"reasoning_effort":"medium","chat_template_kwargs":{"truncate_history_thinking":false}}"#.utf8))
        XCTAssertEqual(medium["medium_effort"] as? Bool, true)
        XCTAssertEqual(medium["truncate_history_thinking"] as? Bool, false)
    }

    func testStrictUnsupportedAndConflictingControls() {
        for body in [#"{"reasoning_effort":"off","enable_thinking":true}"#,
                     #"{"reasoning_effort":"medium","medium_effort":false}"#,
                     #"{"reasoning_effort":"high","reasoning":{"effort":"medium"}}"#,
                     #"{"enable_thinking":true,"reasoning":{"enabled":false}}"#,#"{"enable_thinking":"false"}"#,
                     #"{"reasoning_effort":"low"}"#,
                     #"{"preserve_thinking":true}"#,
                     #"{"enable_thinking":false,"medium_effort":true}"#,
                     #"{"enable_thinking":false,"chat_template_kwargs":{"enable_thinking":true}}"#] {
            XCTAssertThrowsError(try NemotronSuperPromptContract.additionalContext(body: Data(body.utf8)))
        }
        XCTAssertThrowsError(try NemotronSuperPromptContract.verifiedTemplate(Data("altered".utf8)))
    }

    func testImageOrder() throws {
        let body = Data(#"{"model":"local","messages":[{"role":"user","content":[{"type":"text","text":"before"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AA=="}},{"type":"text","text":"after"}]}]}"#.utf8)
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let messages = try NemotronSuperPromptContract.messages(request.messages)
        let parts = try XCTUnwrap(messages[0]["content"] as? [[String: any Sendable]])
        XCTAssertEqual(parts.compactMap { $0["type"] as? String }, ["text", "image_url", "text"])
    }
}
