import Foundation
import Testing
@testable import darkbloom

@Suite("Report upload capacity")
struct ReportPayloadTests {
    @Test func evidenceFitsWhenProviderLogsAlreadyFillTheServerLimit() throws {
        let line = Data("{\"log\":\"🪻\"}\n".utf8)
        var logs = Data()
        while logs.count + line.count <= ReportPayload.maxBytes { logs.append(line) }
        let padding = ReportPayload.maxBytes - logs.count
        if padding > 0 {
            logs.append(Data(repeating: UInt8(ascii: " "), count: padding - 1))
            logs.append(UInt8(ascii: "\n"))
        }
        let evidence = Data("{\"source\":\"snapshot\"}\n{\"source\":\"devicecheck\"}\n".utf8)
        let body = try ReportPayload.assemble(logs: logs, evidence: evidence)
        #expect(body.count <= 10 * 1024 * 1024)
        #expect(body.suffix(evidence.count) == evidence)
        #expect(String(data: body, encoding: .utf8) != nil)
    }

    @Test func newestCompleteLinesAndEvidenceKeepTheirBoundaries() throws {
        let evidence = Data("{\"evidence\":true}\n".utf8)
        let logs = Data("{\"old\":true}\n{\"new\":true}\n".utf8)
        let body = try ReportPayload.assemble(logs: logs, evidence: evidence, limit: evidence.count + 16)
        #expect(String(decoding: body, as: UTF8.self) == "{\"new\":true}\n{\"evidence\":true}\n")
        let unterminated = try ReportPayload.assemble(logs: Data("{}".utf8), evidence: evidence)
        #expect(String(decoding: unterminated, as: UTF8.self) == "{}\n{\"evidence\":true}\n")
        #expect(try ReportPayload.assemble(logs: logs, evidence: evidence, limit: evidence.count) == evidence)
        #expect(throws: ReportPayload.Failure.self) {
            try ReportPayload.assemble(logs: Data(), evidence: evidence, limit: evidence.count - 1)
        }
    }
}
