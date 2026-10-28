import Foundation

private struct Fixture: Decodable {
    struct Case: Decodable {
        let measured: Int
        let final: QwenResidentSoloCohortReport
    }
    let schema: String
    let cases: [Case]
    let actualSoloFinalReport: Bool
    let actualPerformanceEvidence: Bool
}

@main
private struct ReportEncodingCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw ProbeError("Expected fixture and fresh output directory") }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ProbeError("Encoding output already exists") }
        let raw = try Data(contentsOf: input)
        guard raw.count <= 2 * 1024 * 1024 else { throw ProbeError("Encoding fixture exceeds bound") }
        let fixture = try JSONDecoder().decode(Fixture.self, from: raw)
        guard fixture.schema == "fabricated_solo_report_encoding_cases_v1",
              !fixture.actualSoloFinalReport, !fixture.actualPerformanceEvidence,
              fixture.cases.map(\.measured) == [1, 2, 3] else { throw ProbeError("Encoding fixture scope differs") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        var sizes: [Int] = []
        var oldLimitRejections = 0
        var boundaryAccepted = 0
        var boundaryRejected = 0
        for item in fixture.cases {
            let report = item.final
            guard report.measuredCount == item.measured, report.requests.count == 1 + item.measured,
                  report.resources.budget.sourceNames.count == 1847,
                  report.resources.budget.sourceByteCounts.count == 1847,
                  report.resources.budget.allocationBounds.count == 1847 else {
                throw ProbeError("Actual registered ledger or configured count was lost")
            }
            let data = try QwenResidentSoloOutput.encode(report, maximumBytes: QwenResidentSoloOutput.finalMaximumBytes)
            guard data.last == 10, data.count > QwenResidentSoloOutput.progressMaximumBytes,
                  data.count <= QwenResidentSoloOutput.finalMaximumBytes + 1 else {
                throw ProbeError("Actual final encoding does not exercise the corrected bound")
            }
            var rejected = false
            do { _ = try QwenResidentSoloOutput.encode(report, maximumBytes: QwenResidentSoloOutput.progressMaximumBytes) }
            catch { rejected = true; oldLimitRejections += 1 }
            guard rejected else { throw ProbeError("Old final limit did not reproduce the failure") }
            let decoded = try JSONDecoder().decode(QwenResidentSoloCohortReport.self, from: data)
            guard try canonicalJSONData(decoded) == canonicalJSONData(report),
                  decoded.resources.budget.sourceNames == report.resources.budget.sourceNames,
                  decoded.resources.budget.sourceByteCounts == report.resources.budget.sourceByteCounts,
                  decoded.resources.budget.allocationBounds == report.resources.budget.allocationBounds else {
                throw ProbeError("Encoding lost report or full per-tensor evidence")
            }
            try data.write(to: output.appendingPathComponent("report-\(item.measured).jsonl"), options: .withoutOverwriting)
            sizes.append(data.count - 1)
        }
        for cap in [QwenResidentSoloOutput.progressMaximumBytes, QwenResidentSoloOutput.finalMaximumBytes] {
            // ASCII JSON strings add exactly two quote bytes; the LF is framing.
            let exact = try QwenResidentSoloOutput.encode(String(repeating: "x", count: cap - 2), maximumBytes: cap)
            guard exact.count == cap + 1, exact.last == 10 else { throw ProbeError("Exact boundary differs") }
            boundaryAccepted += 1
            var rejected = false
            do { _ = try QwenResidentSoloOutput.encode(String(repeating: "x", count: cap - 1), maximumBytes: cap) }
            catch { rejected = true; boundaryRejected += 1 }
            guard rejected else { throw ProbeError("Oversized output was accepted") }
        }
        // Shared reader limits stay unchanged; seven records is the maximum 1+3 cohort.
        let envelope = 6 * QwenResidentSoloOutput.progressMaximumBytes + QwenResidentSoloOutput.finalMaximumBytes + 7
        guard QwenResidentSoloOutput.finalMaximumBytes + 1 < 32 * 1024 * 1024,
              envelope < 160 * 1024 * 1024 else { throw ProbeError("Bound exceeds existing pipe limits") }
        let result: [String: Any] = ["kind": "solo_report_encoding_check", "reportBytes": sizes,
            "oldLimitRejections": oldLimitRejections, "boundaryAccepted": boundaryAccepted,
            "boundaryRejected": boundaryRejected, "maximumCohortBytesIncludingLF": envelope,
            "actualPerformanceEvidence": false, "modelOrKernelExecuted": false]
        var data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
