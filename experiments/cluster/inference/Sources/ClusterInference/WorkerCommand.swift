import CoreFoundation
import Foundation

let workerMaximumLineBytes = 2 * 1024 * 1024

struct WorkerInferenceRequest: Encodable {
    let version = 5
    let type = "infer"
    let epoch: String
    let sequence: Int
    let requestID: String
    let prompt: [Int]
    let outputTokens: Int
    let chunkSize: Int
    let timeoutSeconds: Int
    let captureLogits: Bool
    let teacherTokens: [Int]?
}

struct WorkerShutdown: Encodable {
    let version = 5
    let type = "shutdown"
    let epoch: String
    let sequence: Int
}

enum WorkerCommand: Encodable {
    case infer(WorkerInferenceRequest)
    case shutdown(WorkerShutdown)

    var epoch: String {
        switch self { case .infer(let request): request.epoch; case .shutdown(let request): request.epoch }
    }
    var sequence: Int {
        switch self { case .infer(let request): request.sequence; case .shutdown(let request): request.sequence }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .infer(let request): try container.encode(request)
        case .shutdown(let request): try container.encode(request)
        }
    }

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> WorkerCommand {
        guard !data.isEmpty, data.count <= workerMaximumLineBytes else {
            throw ProbeError("Worker command exceeds the 2 MiB frame limit or is empty")
        }
        try validateWorkerJSON(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError("Worker command must be a JSON object")
        }
        let version = try workerInteger(object, "version")
        guard version == 5, let type = object["type"] as? String,
            let epoch = object["epoch"] as? String else {
            throw ProbeError("Worker command requires version 5, type and epoch")
        }
        let sequence = try workerInteger(object, "sequence")
        try validateWorkerEnvelope(epoch: epoch, sequence: sequence)
        let common: Set<String> = ["version", "type", "epoch", "sequence"]
        switch type {
        case "shutdown":
            guard Set(object.keys) == common else { throw ProbeError("Invalid shutdown fields") }
            return .shutdown(WorkerShutdown(epoch: epoch, sequence: sequence))
        case "infer":
            let required = common.union(["requestID", "prompt", "outputTokens", "chunkSize", "timeoutSeconds", "captureLogits"])
            guard required.isSubset(of: Set(object.keys)),
                Set(object.keys).isSubset(of: required.union(["teacherTokens"])),
                let requestID = object["requestID"] as? String,
                let capture = object["captureLogits"] as? NSNumber,
                CFGetTypeID(capture) == CFBooleanGetTypeID() else {
                throw ProbeError("Invalid or missing inference fields")
            }
            let prompt = try workerTokens(object, "prompt")
            let teacher = try object["teacherTokens"].map { _ in try workerTokens(object, "teacherTokens") }
            let request = WorkerInferenceRequest(epoch: epoch, sequence: sequence, requestID: requestID,
                prompt: prompt, outputTokens: try workerInteger(object, "outputTokens"),
                chunkSize: try workerInteger(object, "chunkSize"),
                timeoutSeconds: try workerInteger(object, "timeoutSeconds"),
                captureLogits: capture.boolValue, teacherTokens: teacher)
            try validateWorkerInference(request)
            return .infer(request)
        default: throw ProbeError("Unknown worker command type")
        }
    }
}

func validateWorkerEnvelope(epoch: String, sequence: Int) throws {
    guard epoch.utf8.count == 32, epoch.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
        (1...1_000_000_000).contains(sequence) else {
        throw ProbeError("Worker epoch must be 32 lowercase hexadecimal bytes and sequence must be 1...1000000000")
    }
}

func validateWorkerInference(_ request: WorkerInferenceRequest) throws {
    try validateWorkerEnvelope(epoch: request.epoch, sequence: request.sequence)
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:-".utf8)
    guard (1...128).contains(request.requestID.utf8.count), request.requestID.utf8.allSatisfy(allowed.contains),
        !request.prompt.isEmpty, request.prompt.allSatisfy({ $0 >= 0 }),
        (1...4096).contains(request.outputTokens), (1...32768).contains(request.chunkSize),
        (1...300).contains(request.timeoutSeconds) else {
        throw ProbeError("Worker inference fields exceed their bounds")
    }
    if let teacher = request.teacherTokens {
        guard teacher.count == request.outputTokens - 1, teacher.allSatisfy({ $0 >= 0 }) else {
            throw ProbeError("Worker teacher tokens must contain outputTokens minus one nonnegative IDs")
        }
    }
}

private func workerInteger(_ object: [String: Any], _ key: String) throws -> Int {
    guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
        let value = Int(number.stringValue) else { throw ProbeError("Worker field \(key) must be an integer") }
    return value
}

private func workerTokens(_ object: [String: Any], _ key: String) throws -> [Int] {
    guard let values = object[key] as? [Any] else { throw ProbeError("Worker field \(key) must be an integer array") }
    return try values.map { try workerInteger([key: $0], key) }
}
