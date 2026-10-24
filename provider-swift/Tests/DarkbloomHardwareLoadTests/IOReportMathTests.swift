import Testing

@testable import DarkbloomHardwareLoad

struct IOReportMathTests {
    /// M4 Max `voltage-states9`: positional and deliberately non-monotonic.
    private let m4MaxGPUTable: [Double] = [
        338, 618, 796, 924, 952, 1056, 1062, 1182, 1182, 1312, 1242, 1380, 1326, 1470, 1578,
    ]

    /// GPUPH carries 16 states: OFF then P1…P15.
    private func gpuph(_ residency: [String: Int64]) -> [IOReportState] {
        (["OFF"] + (1...15).map { "P\($0)" }).map {
            IOReportState(name: $0, residency: residency[$0] ?? 0)
        }
    }

    /// PMP DCS histograms carry 32 buckets labelled "32GB/s" … "1024GB/s".
    private func dcs(_ residency: [Int: Int64]) -> [IOReportState] {
        (0..<32).map { IOReportState(name: "\(32 * ($0 + 1))GB/s", residency: residency[$0] ?? 0) }
    }

    @Test func gpuFrequencyMapsStatesPositionallyAndIgnoresOff() {
        let reading = IOReportMath.gpuFrequency(
            gpuph(["OFF": 500, "P1": 300, "P15": 100]), tableMHz: m4MaxGPUTable)
        let expected: Double = (338 * 300 + 1578 * 100) / 400
        #expect(reading == CounterReading(value: expected, moved: true))
    }

    @Test func gpuFrequencyUsesTablePositionNotSortedOrder() {
        let reading = IOReportMath.gpuFrequency(gpuph(["P11": 10]), tableMHz: m4MaxGPUTable)
        #expect(reading?.value == 1242)
    }

    @Test func idleGPUReadsZeroAndHasNotMoved() {
        let reading = IOReportMath.gpuFrequency(gpuph(["OFF": 1000]), tableMHz: m4MaxGPUTable)
        #expect(reading == CounterReading(value: 0, moved: false))
        #expect(IOReportMath.gpuFrequency(gpuph([:]), tableMHz: []) == nil)
    }

    @Test func histogramTreatsUnderflowBucketAsZero() {
        #expect(IOReportMath.histogramBandwidth(dcs([0: 900, 13: 100]))?.value == 44.8)
        #expect(IOReportMath.histogramBandwidth(dcs([0: 1000])) == CounterReading(value: 0, moved: true))
    }

    @Test func decodeLikeHistogramReadsNearPeakBandwidth() {
        let reading = IOReportMath.histogramBandwidth(dcs([13: 600, 14: 400]))
        let expected: Double = (448 * 600 + 480 * 400) / 1000
        #expect(reading?.value == expected)
    }

    @Test func unpoweredLaneHasNotMoved() {
        let lane = (0..<32).map { IOReportState(name: "\(2 * ($0 + 1))GB/s", residency: 0) }
        #expect(IOReportMath.histogramBandwidth(lane) == CounterReading(value: 0, moved: false))
    }

    @Test func bucketLabelsTolerateLeadingSpaces() {
        #expect(IOReportMath.bucketLabel("  128GB/s") == 128)
        #expect(IOReportMath.bucketLabel("0.250W") == 0.25)
        #expect(IOReportMath.bucketLabel("n/a") == 0)
    }

    @Test func energyConvertsByUnitLabel() {
        #expect(IOReportMath.watts(energy: 40_000_000_000, unit: "nJ", seconds: 1) == 40)
        #expect(IOReportMath.watts(energy: 500, unit: "mJ", seconds: 0.5) == 1)
        #expect(IOReportMath.watts(energy: 1, unit: "kWh", seconds: 1) == nil)
        #expect(IOReportMath.watts(energy: 1, unit: "nJ", seconds: 0) == nil)
    }
}
