import Foundation
import MLXLMServer
import XCTest
@testable import ProviderCore

final class GPTOSSCommentaryConformanceTests: XCTestCase {
    private let flag = "DARKBLOOM_GPTOSS_COMMENTARY_CONTENT"
    private var previous: String?
    override func setUp() {
        super.setUp()
        previous = ProcessInfo.processInfo.environment[flag]
        setenv(flag, "1", 1)
    }
    override func tearDown() {
        if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        super.tearDown()
    }

    private func filtered(_ text: String, width: Int) -> String {
        var filter = HarmonyFinalHeaderFilter()
        let chars = Array(text)
        var result = ""
        for start in stride(from: 0, to: chars.count, by: width) {
            result += filter.ingest(String(chars[start..<min(start + width, chars.count)]))
        }
        return result + filter.finish()
    }

    func testRecipientlessPreambleReachesStreamingContent() {
        let output = "<|channel|>analysis<|message|>Need weather.<|end|><|start|>assistant"
            + "<|channel|>commentary<|message|>Checking Paris.<|end|>"
        for width in [1, 2, 3, 7, 4096] {
            var parser = StreamingReasoningParser(format: .harmony)
            var parsed = [ParsedReasoning]()
            for char in filtered(output, width: width) { parsed += parser.parse(String(char)) }
            parsed += parser.finish()
            XCTAssertEqual(parsed.map(\.content).joined(), "Checking Paris.")
            XCTAssertEqual(parsed.compactMap(\.reasoningContent).joined(), "Need weather.")
        }
    }

    func testRecipientlessPreambleReachesCollectedContent() {
        let output = "<|channel|>commentary<|message|>Checking Paris.<|end|>"
        XCTAssertEqual(ReasoningParser(format: .harmony).parse(filtered(output, width: 1)).content, "Checking Paris.")
    }

    func testToolRecipientsOnEitherSideOfChannelAreUnchanged() {
        for header in [
            "<|start|>assistant to=functions.get_weather<|channel|>commentary",
            "<|start|>assistant<|channel|>commentary to=functions.get_weather",
        ] {
            let output = header + "<|message|>{\"city\":\"Paris\"}<|call|>"
            for width in [1, 3, 4096] { XCTAssertEqual(filtered(output, width: width), output) }
        }
    }

    func testOffAndAbsentKeepCommentaryDropped() {
        let output = "<|channel|>commentary<|message|>Checking Paris.<|end|>"
        for value in ["0", "off", "false", "no"] {
            setenv(flag, value, 1)
            XCTAssertEqual(filtered(output, width: 1), output)
        }
        unsetenv(flag)
        XCTAssertEqual(filtered(output, width: 1), output)
    }
}
