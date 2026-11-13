import Foundation
import MLXLMServer
import XCTest
@testable import ProviderCore

final class QwenStrayThinkCloseConformanceTests: XCTestCase {
    private let flag = "DARKBLOOM_QWEN_ABSORB_STRAY_THINK_CLOSE"
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

    private func content(_ text: String, width: Int, type: String) throws -> String {
        let absorbs = ToolChoiceEnforcementPolicy.absorbsStrayThinkClose(
            .init(modelId: "qwen3.6-35b-a3b-vl-mtp-mxfp8", modelType: type))
        var router = NativeToolStreamRouter(handler: nil, requiresToolCall: false,
            nativePrefix: "<think></think>", absorbStrayThinkClose: absorbs)
        let chars = Array(text)
        var events = [MLXServerGenerationEvent]()
        for start in stride(from: 0, to: chars.count, by: width) {
            events += try router.process(String(chars[start..<min(start + width, chars.count)]))
        }
        events += try router.finishText()
        return events.compactMap { event -> String? in
            if case .parsed(let parsed) = event {
                XCTAssertNil(parsed.reasoningContent)
                return parsed.content
            }
            XCTFail("Expected native parsed event")
            return nil
        }.joined()
    }

    func testStrayAndRepeatedClosesAreAbsorbedAtEveryChunking() throws {
        for type in ["qwen3_5", "qwen3_5_moe", "qwen4_exp", "qwen4_exp_text"] {
            for width in [1, 2, 3, 7, 4096] {
                XCTAssertEqual(try content("before</think></think>after", width: width, type: type), "beforeafter")
            }
        }
    }

    func testPartialMarkerRemainsLiteralAtEndOfStream() throws {
        XCTAssertEqual(try content("before</thi", width: 1, type: "qwen3_5"), "before</thi")
    }

    func testSwitchOffPreservesLiteralClose() throws {
        for value in ["0", "off", "false", "no"] {
            setenv(flag, value, 1)
            XCTAssertEqual(try content("before</think>after", width: 1, type: "qwen3_5"), "before</think>after")
        }
        unsetenv(flag)
        XCTAssertEqual(try content("before</think>after", width: 1, type: "qwen3_5"), "before</think>after")
    }
}
