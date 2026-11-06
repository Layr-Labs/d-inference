import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Foundation

enum WorkerFailure: Error { case invalid(String) }

struct WorkerConfiguration {
    let load: QwenResidentLoadConfiguration

    init(arguments: [String], now: UInt64) throws {
        let names: Set<String> = ["--model-dir", "--rank", "--stage-cut", "--membership-epoch",
            "--model-id", "--artifact-sha256", "--configuration-sha256", "--peer0-id",
            "--peer0-build-sha256", "--peer1-id", "--peer1-build-sha256", "--deadline-uptime-nanoseconds"]
        guard arguments.count == names.count * 2 else { throw WorkerFailure.invalid("Expected exactly twelve worker flag/value pairs") }
        var fields: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index], value = arguments[index + 1]
            guard names.contains(key), fields[key] == nil, !value.isEmpty, value.utf8.count <= 4096,
                  !value.contains("\0") else { throw WorkerFailure.invalid("Unknown, duplicate or empty worker argument") }
            fields[key] = value
        }
        func integer(_ key: String) throws -> Int {
            guard let value = Int(fields[key]!), String(value) == fields[key] else { throw WorkerFailure.invalid("Worker integer must be canonical") }
            return value
        }
        func hash(_ key: String) throws -> String {
            let value = fields[key]!
            guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw WorkerFailure.invalid("Worker SHA256 must be lowercase hexadecimal")
            }
            return value
        }
        let rank = try integer("--rank"), cut = try integer("--stage-cut")
        guard (0...1).contains(rank), [12, 16].contains(cut), fields["--model-dir"]!.hasPrefix("/"),
              fields["--model-id"] == "registered_qwen35_9b",
              let epoch = UUID(uuidString: fields["--membership-epoch"]!),
              epoch.uuidString.lowercased() == fields["--membership-epoch"],
              let deadline = UInt64(fields["--deadline-uptime-nanoseconds"]!),
              String(deadline) == fields["--deadline-uptime-nanoseconds"],
              deadline > now, deadline - now <= 300_000_000_000 else {
            throw WorkerFailure.invalid("Worker requires registered9B, rank0|1, cut12|16 and a <=300-second local lifetime")
        }
        let peers = try (0...1).map { index -> ClusterWorkerPeer in
            let label = fields["--peer\(index)-id"]!
            guard label.utf8.count <= 128, label.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw WorkerFailure.invalid("Worker peer label is invalid")
            }
            return .init(id: label, buildSHA256: try hash("--peer\(index)-build-sha256"))
        }
        guard peers[0].id != peers[1].id else { throw WorkerFailure.invalid("Worker peers must be distinct") }
        load = .init(identity: .init(membershipEpoch: epoch, modelID: fields["--model-id"]!,
            artifactSHA256: try hash("--artifact-sha256"), configurationSHA256: try hash("--configuration-sha256"), peers: peers),
            modelDirectory: URL(fileURLWithPath: fields["--model-dir"]!), rank: rank, stageCut: cut,
            deadlineUptimeNanoseconds: deadline)
    }
}
