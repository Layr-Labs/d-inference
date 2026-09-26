import Foundation

/// Reserve room for diagnostic evidence under the coordinator's raw-body limit.
enum ReportPayload {
    // Mirrors coordinator/api/log_report_handlers.go maxLogReportBodySize.
    static let maxBytes = 10 * 1024 * 1024
    enum Failure: Error { case evidenceTooLarge }

    static func assemble(logs: Data, evidence: Data, limit: Int = maxBytes) throws -> Data {
        guard evidence.count <= limit else { throw Failure.evidenceTooLarge }
        let newline = UInt8(ascii: "\n")
        let separator = !logs.isEmpty && logs.last != newline ? 1 : 0
        if logs.count <= limit - evidence.count - separator {
            var result = logs
            if separator > 0 { result.append(newline) }
            result.append(evidence)
            return result
        }
        // Keep the newest complete provider log lines, preserving all evidence.
        let budget = max(0, limit - evidence.count - 1)
        let tail = logs.suffix(budget)
        var result = Data()
        if let firstNewline = tail.firstIndex(of: newline) {
            result.append(contentsOf: tail[tail.index(after: firstNewline)...])
            if !result.isEmpty && result.last != newline { result.append(newline) }
        }
        result.append(evidence)
        return result
    }
}
