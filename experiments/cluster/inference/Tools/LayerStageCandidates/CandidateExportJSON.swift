import Foundation

/// Reuse the existing duplicate-key/depth/string scanner while allowing config
/// numbers. Only a throwaway scanning copy replaces each validated number with
/// zero. The original bytes reach native Plan unchanged and own its fingerprint.
func validateCandidateExportConfigurationJSON(_ data: Data) throws {
    let bytes = Array(data)
    var scan: [UInt8] = []
    scan.reserveCapacity(bytes.count)
    var index = 0
    while index < bytes.count {
        let byte = bytes[index]
        if byte == 34 {
            scan.append(byte); index += 1
            while index < bytes.count {
                let next = bytes[index]
                scan.append(next); index += 1
                if next == 92 {
                    if index < bytes.count { scan.append(bytes[index]); index += 1 }
                } else if next == 34 { break }
            }
        } else if byte == 45 || (48...57).contains(byte) {
            let start = index
            repeat { index += 1 } while index < bytes.count
                && ((48...57).contains(bytes[index]) || [43, 45, 46, 69, 101].contains(bytes[index]))
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            guard index - start <= 128,
                  token.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#,
                    options: .regularExpression) != nil,
                  let number = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]),
                    options: [.fragmentsAllowed]) as? NSNumber,
                  number.doubleValue.isFinite else {
                throw ProbeError("Candidate configuration has an invalid or oversized JSON number")
            }
            scan.append(48)
        } else {
            scan.append(byte); index += 1
        }
    }
    try validateWorkerJSON(Data(scan))
}

enum QwenCandidateExportEncoding {
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// Small bounds can be used by pure callers; CLI always uses the fixed cap.
    static func record<T: Encodable>(_ value: T,
        maximumBytes: Int = QwenCandidateExport.maximumOutputBytes) throws -> Data {
        guard (1...QwenCandidateExport.maximumOutputBytes).contains(maximumBytes) else {
            throw ProbeError("Candidate output byte limit is invalid")
        }
        var bytes = try data(value)
        guard bytes.count < maximumBytes else { throw ProbeError("Candidate output exceeds its byte limit") }
        bytes.append(10)
        return bytes
    }
}
