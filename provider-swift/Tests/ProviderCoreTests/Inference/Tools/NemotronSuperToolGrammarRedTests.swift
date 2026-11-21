import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// RED CONTROL (today's API only): Nemotron 3.5 Super's `auto` calls, text and
/// image, under the call grammar. Today no grammar path holds them.
@Suite("Call grammar: Nemotron 3.5 Super auto calls (red control)")
struct NemotronSuperToolGrammarRedTests {
    private typealias L = NemotronToolFixture
    static let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="

    static func body(image: Bool) -> Data {
        let content = image
            ? #"[{"type":"text","text":"Scroll down."},{"type":"image_url","image_url":{"url":"\#(png)"}}]"#
            : #""Scroll down.""#
        return Data((#"{"model":"\#(NemotronSuperLocalBinding.modelID)","messages":[{"role":"user","content":\#(content)}],"#
            + #""max_tokens":512,"tools":"# + L.tools + "}").utf8)
    }

    @Test(arguments: [true, false])
    func textAndImageRequestsHoldTheirCalls(image: Bool) throws {
        let body = Self.body(image: image)
        let plan = try NemotronSuperRequestPlan(body: body)
        let constraint = try #require(QwenStrictToolGrammar.constraint(prepared: plan.toolPolicy, request: plan.request,
            parser: .nemotron, tokenizer: L.handle, modelType: NemotronSuperRequestPlan.modelType, defaultMaxTokens: 512,
            stopTokenIDs: L.stops, promptTokens: NemotronByteTestTokenizer.tokens(NemotronByteTestTokenizer.prompt(thinking: true)),
            runsTokenConstraints: true))
        let open = "The page continues below.</think><tool_call>\n<function=computer>\n"
        #expect(L.allows("<parameter=action>\nscroll\n</parameter>\n", constraint, after: open))
        #expect(!L.allows("<parameter=action>\nscroll_down\n", constraint, after: open))
    }
}
