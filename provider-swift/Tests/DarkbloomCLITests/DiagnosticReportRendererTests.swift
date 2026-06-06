import Testing
import ProviderCore
@testable import darkbloom

@Test func rendererGroupsBySectionWithFixLines() {
    let diags = [
        Diagnostic(section: .trust, name: "trust level", level: .warn,
                   message: "self_signed / online — not earning.", fix: "run `darkbloom enroll`"),
        Diagnostic(section: .attestationKey, name: "se key sign test", level: .fail,
                   message: "key cannot sign (-25308).", fix: "log in at the console"),
        Diagnostic(section: .billing, name: "usage reporting", level: .pass,
                   message: "412 requests reported.", fix: nil),
    ]
    let out = DiagnosticReportRenderer.render(diags)

    // Sections appear in canonical order: attestationKey before trust before billing.
    let keyIdx = out.range(of: "ATTESTATION KEY")
    let trustIdx = out.range(of: "COORDINATOR TRUST")
    let billIdx = out.range(of: "BILLING")
    #expect(keyIdx != nil && trustIdx != nil && billIdx != nil)
    #expect(out.range(of: "ATTESTATION KEY")!.lowerBound < out.range(of: "COORDINATOR TRUST")!.lowerBound)
    #expect(out.range(of: "COORDINATOR TRUST")!.lowerBound < out.range(of: "BILLING")!.lowerBound)

    // Markers + fix lines render.
    #expect(out.contains("[FAIL] se key sign test"))
    #expect(out.contains("↳ fix: log in at the console"))
    #expect(out.contains("[PASS] usage reporting"))
    // A passing check with nil fix emits no fix line for it.
    #expect(!out.contains("↳ fix: \n"))
}

@Test func rendererFailureVerdictRespectsStrict() {
    let warnOnly = [Diagnostic(section: .trust, name: "t", level: .warn, message: "m")]
    #expect(DiagnosticReportRenderer.hasFailure(warnOnly, strict: false) == false)
    #expect(DiagnosticReportRenderer.hasFailure(warnOnly, strict: true) == true)

    let withFail = [Diagnostic(section: .trust, name: "t", level: .fail, message: "m")]
    #expect(DiagnosticReportRenderer.hasFailure(withFail, strict: false) == true)
}
