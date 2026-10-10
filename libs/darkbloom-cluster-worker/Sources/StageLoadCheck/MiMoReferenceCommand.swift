import DarkbloomClusterRuntime
import Darwin
import Foundation

/// `darkbloom-cluster-stage-check mimo-reference`: one Mac, both MiMo stages
/// of one cut in one process, one qualification request through them. The
/// single-Mac reference a pair's tokens are compared with. It needs a Mac that
/// can hold the whole text model (156 GiB of tensors).
enum MiMoReferenceCommand {
    static let name = "mimo-reference"
    static let usage = "usage: mimo-reference --model-dir /ABS/PATH --request REQUEST.json --stage-cut CUT "
        + "--report NEW-REPORT.json [--deadline-seconds 10...1800] [--residency on|off]\n  "
        + GateMeasurement.usage

    static func run(_ arguments: [String]) throws -> Int32 {
        let fields = try StageCheckArguments.parse(arguments, allowed: ["--model-dir", "--request", "--stage-cut",
            "--report", "--deadline-seconds", "--residency", GateMeasurement.modeArgument, GateMeasurement.outputArgument])
        guard let path = fields["--model-dir"], path.hasPrefix("/"), let requestPath = fields["--request"],
              let reportPath = fields["--report"], reportPath.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: reportPath),
              let cut = fields["--stage-cut"].flatMap(Int.init),
              let seconds = Int(fields["--deadline-seconds"] ?? "900"), (10...1800).contains(seconds),
              ["on", "off"].contains(fields["--residency"] ?? "on") else {
            throw StageLoadCheck.Failure(usage)
        }
        // The qualification request file, read here without its package: the
        // runtime re-validates every field against the model's own profile.
        struct RequestFile: Decodable {
            let requestID: String, modelID: String
            let promptTokenIDs: [Int], stopTokenIDs: [Int]
            let chunkSize: Int, outputCount: Int
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: requestPath))
        guard data.count <= 1 << 20 else { throw StageLoadCheck.Failure("The request file exceeds 1 MiB") }
        let file = try JSONDecoder().decode(RequestFile.self, from: data)
        guard let id = UUID(uuidString: file.requestID),
              ClusterResidentModelCatalog.entry(runtimeModelID: file.modelID)?.family == .mimoV26 else {
            throw StageLoadCheck.Failure("The request is not for a registered MiMo model")
        }
        try GateMeasurement.configure(fields)
        let started = DispatchTime.now().uptimeNanoseconds
        // Covers a native call that never returns; nothing is released by it.
        signal(SIGALRM) { _ in Darwin._exit(124) }
        alarm(UInt32(seconds + 5))
        try ProcessDeadline.arm(uptimeNanoseconds: started + UInt64(seconds + 5) * 1_000_000_000, status: 124)
        let result = try MiMoStagedReference.run(modelDirectory: URL(fileURLWithPath: path), stageCut: cut,
            request: .init(requestID: id, promptTokenIDs: file.promptTokenIDs, stopTokenIDs: file.stopTokenIDs,
                           chunkSize: file.chunkSize, outputCount: file.outputCount),
            deadlineUptimeNanoseconds: started + UInt64(seconds) * 1_000_000_000,
            residency: fields["--residency"] != "off")
        alarm(0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var encoded = try encoder.encode(result)
        encoded.append(10)
        try encoded.write(to: URL(fileURLWithPath: reportPath), options: [.withoutOverwriting])
        print(String(decoding: encoded, as: UTF8.self), terminator: "")
        return result.modelsReleased.allSatisfy { $0 } ? 0 : 2
    }
}
