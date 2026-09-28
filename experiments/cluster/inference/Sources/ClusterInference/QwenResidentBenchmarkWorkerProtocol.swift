import CoreFoundation
import Foundation

struct QwenResidentBenchmarkWorkerRequest: Encodable, Equatable {
    let requestID: String
    let epoch: String
    enum CodingKeys: String, CodingKey { case requestID = "request_id", epoch }
}

struct QwenResidentBenchmarkWorkerOpen: Encodable, Equatable {
    let schema = QwenResidentBenchmarkWorkerCommand.schema
    let type = "open"
    let cohortID: String
    let requests: [QwenResidentBenchmarkWorkerRequest]
    enum CodingKeys: String, CodingKey { case schema, type, cohortID = "cohort_id", requests }
}

struct QwenResidentBenchmarkWorkerRun: Encodable, Equatable {
    let schema = QwenResidentBenchmarkWorkerCommand.schema
    let type = "run"
    let cohortID: String
    let sequence: Int
    let requestID: String
    let epoch: String
    enum CodingKeys: String, CodingKey {
        case schema, type, cohortID = "cohort_id", sequence, requestID = "request_id", epoch
    }
}

struct QwenResidentBenchmarkWorkerShutdown: Encodable, Equatable {
    let schema = QwenResidentBenchmarkWorkerCommand.schema
    let type = "shutdown"
    let cohortID: String
    let sequence: Int
    enum CodingKeys: String, CodingKey { case schema, type, cohortID = "cohort_id", sequence }
}

/// New control namespace; the existing worker v5 envelope and broad inference
/// admission are not reused. The unchanged WorkerLineReader still enforces its
/// 2 MiB framing bound; this decoder independently caps a complete line at 4 KiB.
enum QwenResidentBenchmarkWorkerCommand: Encodable {
    static let schema = "qwen_resident_benchmark_worker_v1"
    static let maximumEncodedBytes = 4096
    static let requestCount = 4
    static let warmupCount = 1
    static let suffixes = [":warmup:0", ":measured:0", ":measured:1", ":measured:2"]

    case open(QwenResidentBenchmarkWorkerOpen)
    case run(QwenResidentBenchmarkWorkerRun)
    case shutdown(QwenResidentBenchmarkWorkerShutdown)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .open(let value): try container.encode(value)
        case .run(let value): try container.encode(value)
        case .shutdown(let value): try container.encode(value)
        }
    }

    func canonicalData() throws -> Data {
        try validate()
        let bytes = try canonicalJSONData(self)
        guard bytes.count <= Self.maximumEncodedBytes else {
            throw ProbeError("Resident benchmark command exceeds 4 KiB")
        }
        return bytes
    }

    /// Also used by the sequence owner so memberwise construction cannot bypass
    /// the command contract. This validates metadata, never model eligibility.
    func validate() throws {
        switch self {
        case .open(let value):
            try Self.validateCohortID(value.cohortID)
            guard value.requests.count == Self.requestCount else {
                throw ProbeError("Resident benchmark open requires exactly four requests")
            }
            var epochs = Set<String>()
            for (ordinal, request) in value.requests.enumerated() {
                try Self.validateEpoch(request.epoch)
                guard request.requestID == value.cohortID + Self.suffixes[ordinal],
                      epochs.insert(request.epoch).inserted else {
                    throw ProbeError("Resident benchmark open request order, ID or epoch differs")
                }
            }
        case .run(let value):
            try Self.validateCohortID(value.cohortID)
            try Self.validateEpoch(value.epoch)
            guard (1...Self.requestCount).contains(value.sequence),
                  value.requestID == value.cohortID + Self.suffixes[value.sequence - 1] else {
                throw ProbeError("Resident benchmark run ID or sequence differs")
            }
        case .shutdown(let value):
            try Self.validateCohortID(value.cohortID)
            guard value.sequence == Self.requestCount + 1 else {
                throw ProbeError("Resident benchmark shutdown requires sequence five")
            }
        }
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw ProbeError("Resident benchmark command is empty or exceeds 4 KiB")
        }
        try validateWorkerJSON(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema"] as? String == schema,
              let type = object["type"] as? String,
              let cohortID = object["cohort_id"] as? String else {
            throw ProbeError("Resident benchmark command requires its schema, type and cohort ID")
        }
        let common: Set<String> = ["schema", "type", "cohort_id"]
        let command: Self
        switch type {
        case "open":
            guard Set(object.keys) == common.union(["requests"]),
                  let rows = object["requests"] as? [[String: Any]], rows.count == requestCount else {
                throw ProbeError("Resident benchmark open fields or request count differ")
            }
            let requests = try rows.map { row -> QwenResidentBenchmarkWorkerRequest in
                guard Set(row.keys) == ["request_id", "epoch"],
                      let requestID = row["request_id"] as? String,
                      let epoch = row["epoch"] as? String else {
                    throw ProbeError("Resident benchmark request fields differ")
                }
                return .init(requestID: requestID, epoch: epoch)
            }
            command = .open(.init(cohortID: cohortID, requests: requests))
        case "run":
            guard Set(object.keys) == common.union(["sequence", "request_id", "epoch"]),
                  let requestID = object["request_id"] as? String,
                  let epoch = object["epoch"] as? String else {
                throw ProbeError("Resident benchmark run fields differ")
            }
            command = .run(.init(cohortID: cohortID, sequence: try integer(object, "sequence"),
                                 requestID: requestID, epoch: epoch))
        case "shutdown":
            guard Set(object.keys) == common.union(["sequence"]) else {
                throw ProbeError("Resident benchmark shutdown fields differ")
            }
            command = .shutdown(.init(cohortID: cohortID, sequence: try integer(object, "sequence")))
        default:
            throw ProbeError("Unknown resident benchmark command")
        }
        try command.validate()
        return command
    }

    private static func integer(_ object: [String: Any], _ key: String) throws -> Int {
        guard let number = object[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), let value = Int(number.stringValue) else {
            throw ProbeError("Resident benchmark sequence must be an integer")
        }
        return value
    }

    private static func validateCohortID(_ value: String) throws {
        let labels = value.split(separator: ":", omittingEmptySubsequences: false)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-".utf8)
        guard value.utf8.count <= 129, labels.count == 2,
              labels.allSatisfy({ (1...64).contains($0.utf8.count) && $0.utf8.allSatisfy(allowed.contains) }) else {
            throw ProbeError("Resident benchmark cohort ID requires two bounded colon-free ASCII labels")
        }
    }

    private static func validateEpoch(_ value: String) throws {
        guard value.utf8.count == 32,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ProbeError("Resident benchmark epoch requires 32 lowercase hexadecimal bytes")
        }
    }
}
