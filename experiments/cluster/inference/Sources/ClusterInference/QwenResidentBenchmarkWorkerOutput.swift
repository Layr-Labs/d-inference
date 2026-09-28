import Foundation

struct QwenResidentBenchmarkWorkerEvent<Record: Encodable>: Encodable {
    let schema = QwenResidentBenchmarkWorkerCommand.schema
    let type: String
    let cohortID: String
    let role: String
    let rank: Int?
    let record: Record

    enum CodingKeys: String, CodingKey { case schema, type, cohortID = "cohort_id", role, rank, record }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(type, forKey: .type)
        try container.encode(cohortID, forKey: .cohortID)
        try container.encode(role, forKey: .role)
        try container.encode(rank, forKey: .rank)
        try container.encode(record, forKey: .record)
    }
}

/// Bounds bytes before publication and accounts only successful writes. A write
/// failure is terminal even when a prefix reached the parent; it is never retried.
final class QwenResidentBenchmarkWorkerOutput {
    static let maximumLineBytes = 32 * 1024 * 1024
    static let maximumTotalBytes = 160 * 1024 * 1024
    private(set) var completedBytes = 0
    private(set) var failed = false
    private var writing = false
    private let write: (Data) throws -> Void

    init(write: @escaping (Data) throws -> Void) { self.write = write }

    func publish<T: Encodable>(_ value: T, check: () throws -> Void) throws {
        do {
            guard !failed, !writing else { throw ProbeError("Resident worker output failed or was reentered") }
            writing = true
            defer { writing = false }
            try check()
            guard !failed, writing else { throw ProbeError("Resident worker output failed during its first check") }
            var bytes = try canonicalJSONData(value)
            guard bytes.count <= Self.maximumLineBytes,
                  bytes.count + 1 <= Self.maximumTotalBytes - completedBytes else {
                throw ProbeError("Resident worker output exceeds its line or cohort bound")
            }
            bytes.append(10)
            try check()
            guard !failed, writing else { throw ProbeError("Resident worker output failed before publication") }
            try write(bytes)
            try check()
            guard !failed, writing else { throw ProbeError("Resident worker output was reentered") }
            completedBytes += bytes.count
        } catch { failed = true; throw error }
    }
}
