import Foundation
import Testing

@testable import ProviderCore

/// Pure invariants of the cold-load stage report (T4-04): the fields the
/// `Model loaded:` line and the "model loaded" `.engineHealth` event carry,
/// and the read-not-reset peak rule.
@Suite("Model load stage report")
struct ModelLoadStageReportTests {
    private let gib = 1_073_741_824.0

    private func filled() -> ModelLoadStageReport {
        var report = ModelLoadStageReport(diskGb: 12.1, estimatedGb: 12.1 * 1.2)
        report.evictMs = 5
        report.hashMs = 120
        report.hashPasses = 1
        report.containerLoadMs = 3_000
        report.postLoadProbeMs = 20
        report.buildMs = 400
        report.totalMs = 3_600
        report.steadyActiveGb = 12.4
        return report
    }

    @Test("every stage and residency field is carried, non-negative, and total covers load + build")
    func fieldsAndInvariants() {
        var report = filled()
        report.recordPeak(beforeBytes: Int(1 * gib), afterBytes: Int(15 * gib))

        #expect(report.peakActiveGb == 15)
        #expect(report.peakBaselineGb == 1)
        #expect(!report.peakMasked)
        let ratio = try? #require(report.transientRatio)
        #expect(abs((ratio ?? 0) - 15 / 12.1) < 1e-9)
        #expect(report.totalMs >= report.containerLoadMs + report.buildMs)

        let fields = report.telemetryFields
        for key in [
            "evict_ms", "hash_ms", "hash_passes", "container_load_ms", "post_load_probe_ms",
            "build_ms", "total_ms", "disk_gb", "estimated_gb", "steady_active_gb",
            "peak_baseline_gb", "peak_masked", "peak_active_gb", "transient_ratio",
        ] {
            #expect(fields[key] != nil, "missing telemetry field \(key)")
        }
        for (key, value) in fields {
            if let d = value.value as? Double { #expect(d >= 0, "\(key) negative: \(d)") }
            if let i = value.value as? Int { #expect(i >= 0, "\(key) negative: \(i)") }
        }
        #expect(fields["hash_passes"]?.value as? Int == 1)
        #expect(fields["peak_masked"]?.value as? Bool == false)

        let line = report.logSummary
        #expect(line.contains("total_ms=3600"))
        #expect(line.contains("hash_passes=1"))
        #expect(line.contains("peak_active_gb=15.00"))
        #expect(line.contains("transient_ratio=1.24"))
    }

    @Test("a peak that did not rise above the pre-load high-water mark is reported masked, never re-based")
    func maskedPeak() {
        var report = filled()
        report.recordPeak(beforeBytes: Int(20 * gib), afterBytes: Int(20 * gib))

        #expect(report.peakActiveGb == nil)
        #expect(report.peakMasked)
        #expect(report.transientRatio == nil)
        #expect(report.peakBaselineGb == 20)
        let fields = report.telemetryFields
        #expect(fields["peak_active_gb"] == nil)
        #expect(fields["transient_ratio"] == nil)
        #expect(fields["peak_masked"]?.value as? Bool == true)
        #expect(fields["peak_baseline_gb"]?.value as? Double == 20)
        #expect(report.logSummary.contains("peak_active_gb=masked(baseline=20.00)"))
    }

    @Test("duration → milliseconds keeps sub-second precision")
    func msConversion() {
        #expect(ModelLoadStageReport.ms(.milliseconds(1_500)) == 1_500)
        #expect(abs(ModelLoadStageReport.ms(.microseconds(2_500)) - 2.5) < 1e-9)
        #expect(ModelLoadStageReport.ms(.zero) == 0)
    }
}
