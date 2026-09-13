import Foundation
import ProviderCoreFoundation
import Jinja
import Testing

@Suite("Swift Jinja compatibility")
struct SwiftJinjaCompatibilityTests {
    @Test("normalizes unsupported comment whitespace controls")
    func commentWhitespace() {
        let source = "before \n {#- hidden -#} \n after"
        #expect(normalizeSwiftJinjaTemplate(source) == "before{# hidden #}after")
    }

    @Test("preserves trim before tags following literal braces")
    func literalBraceAdjacency() {
        let source = "object:{ {{- value -}} }\nblock:{ {%- if value %}yes{% endif %}"
        #expect(
            normalizeSwiftJinjaTemplate(source)
                == "object:{{ '{' -}}{{- value -}} }\nblock:{{ '{' -}}{%- if value %}yes{% endif %}")
    }

    @Test("request clock binding matches shared Jinja whitespace semantics and is idempotent")
    func requestClockCompatibility() throws {
        struct Case: Decodable { let template: String; let expected: String }
        struct Corpus: Decodable { let date: String; let cases: [Case] }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf:
            root.appendingPathComponent("fixtures/prompt-contract/v1/request_date_vectors.json")))
        let clock = try #require(PromptRenderDate(corpus.date))
        let context = try clock.templateContext().mapValues { try Value(any: $0) }
        let options = Template.Options(lstripBlocks: true, trimBlocks: true)
        #expect(!corpus.cases.isEmpty)
        for fixture in corpus.cases {
            let normalized = normalizeSwiftJinjaTemplate(fixture.template)
            #expect(normalizeSwiftJinjaTemplate(normalized) == normalized)
            let actual = try Template(normalized, with: options).render(context)
            #expect(actual == fixture.expected, "\(fixture.template)")
        }
    }

    @Test("scan render retains the builtin clock without request context")
    func unboundRequestClock() throws {
        let before = PromptRenderDate.capture()
        let template = try Template(normalizeSwiftJinjaTemplate("{{ strftime_now('%Y-%m-%d') }}"))
        let actual = try template.render([:])
        // The builtin clock uses the provider's local timezone. Compare against
        // that same builtin, not the UTC request contract.
        let builtin = try Template("{{ strftime_now('%Y-%m-%d') }}").render([:])
        #expect(actual == builtin || PromptRenderDate.capture() != before)
    }
}
