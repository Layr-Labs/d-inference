import ProviderCoreFoundation
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
}
