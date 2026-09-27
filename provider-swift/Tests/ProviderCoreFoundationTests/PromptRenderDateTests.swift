import Foundation
import Testing
@testable import ProviderCoreFoundation

struct PromptRenderDateTests {
    @Test func canonicalGregorianDates() {
        for value in ["0001-01-01", "2028-02-29", "2000-02-29", "2026-09-05", "9999-12-31"] {
            #expect(PromptRenderDate(value)?.value == value)
        }
        for value in ["0000-01-01", "1900-02-29", "2026-02-29", "2026-04-31", "2026-13-01",
                      "2026-01-00", "2026-1-01", "2026-01-01Z", "２０２６-01-01", " 2026-01-01"] {
            #expect(PromptRenderDate(value) == nil)
        }
    }

    @Test func directLiteralDateCallsOnly() {
        for source in ["static text", #"{{ strftime_now("%Y-%m-%d") }}"#,
                       "{{ strftime_now ( '%Y-%m-%d' ) }}"] {
            #expect(PromptRenderDate.supportsTemplate(source))
        }
        for source in [#"{{ strftime_now("%H") }}"#, "{{ strftime_now(fmt) }}",
                       "{% set clock = strftime_now %}", #"{{ x.strftime_now("%Y-%m-%d") }}"#,
                       #"{% if false %}{{ strftime_now("%S") }}{% endif %}"#,
                       #"{{ strftime_now("%Y-%m-%d", ignored=true) }}"#] {
            #expect(!PromptRenderDate.supportsTemplate(source))
        }
    }

    @Test func capturesOneUTCDayAcrossMidnight() throws {
        let before = try #require(ISO8601DateFormatter().date(from: "2028-03-01T01:59:59+02:00"))
        let captured = PromptRenderDate.capture(at: before)
        #expect(captured.value == "2028-02-29")
        #expect(PromptRenderDate.capture(at: before.addingTimeInterval(1)).value == "2028-03-01")
        #expect(captured.value == "2028-02-29")
    }
}
