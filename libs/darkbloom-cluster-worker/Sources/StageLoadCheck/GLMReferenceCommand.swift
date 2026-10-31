import DarkbloomClusterRuntime
import Darwin
import Foundation

/// `darkbloom-cluster-stage-check glm-reference`: one Mac, both GLM stages of
/// one cut in one process, one qualification request through them. The
/// single-Mac reference a pair's tokens and step rows are compared with. It
/// needs a Mac that can hold the whole text model (about 170 GB of tensors).
enum GLMReferenceCommand {
    static let name = "glm-reference"
    static let usage = "usage: glm-reference --model-dir /ABS/PATH --request REQUEST.json --stage-cut CUT "
        + "--report NEW-REPORT.json [--deadline-seconds 10...1800]\n  " + GateMeasurement.usage

    static func run(_ arguments: [String]) throws -> Int32 {
        let fields = try StageCheckArguments.parse(arguments, allowed: ["--model-dir", "--request", "--stage-cut",
            "--report", "--deadline-seconds", GateMeasurement.modeArgument, GateMeasurement.outputArgument])
        guard let path = fields["--model-dir"], path.hasPrefix("/"), let requestPath = fields["--request"],
              let reportPath = fields["--report"], reportPath.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: reportPath),
              let cut = fields["--stage-cut"].flatMap(Int.init),
              let seconds = Int(fields["--deadline-seconds"] ?? "1200"), (10...1800).contains(seconds) else {
            throw StageLoadCheck.Failure(usage)
        }
        struct RequestFile: Decodable {
            let requestID: String, modelID: String
            let promptTokenIDs: [Int], stopTokenIDs: [Int]
            let chunkSize: Int, outputCount: Int
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: requestPath))
        guard data.count <= 1 << 20 else { throw StageLoadCheck.Failure("The request file exceeds 1 MiB") }
        let file = try JSONDecoder().decode(RequestFile.self, from: data)
        guard let id = UUID(uuidString: file.requestID),
              ClusterResidentModelCatalog.entry(runtimeModelID: file.modelID)?.family == .glm5Next else {
            throw StageLoadCheck.Failure("The request is not for a registered GLM model")
        }
        try GateMeasurement.configure(fields)
        let started = DispatchTime.now().uptimeNanoseconds
        // Covers a native call that never returns; nothing is released by it.
        signal(SIGALRM) { _ in Darwin._exit(124) }
        alarm(UInt32(seconds + 5))
        try ProcessDeadline.arm(uptimeNanoseconds: started + UInt64(seconds + 5) * 1_000_000_000, status: 124)
        let result = try GLM5NextStagedReference.run(modelDirectory: URL(fileURLWithPath: path), stageCut: cut,
            request: .init(requestID: id, promptTokenIDs: file.promptTokenIDs, stopTokenIDs: file.stopTokenIDs,
                           chunkSize: file.chunkSize, outputCount: file.outputCount),
            deadlineUptimeNanoseconds: started + UInt64(seconds) * 1_000_000_000)
        alarm(0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Host and request binding exactly as the MiMo reference writes them.
        let binding = MiMoReferenceCommand.RequestBinding(promptTokenIDs: file.promptTokenIDs, chunkSize: file.chunkSize,
            outputCount: file.outputCount, stopTokenIDs: file.stopTokenIDs)
        var encoded = Data("{\"host\":".utf8) + (try encoder.encode(MiMoReferenceCommand.Host.local()))
            + Data(",\"request\":".utf8) + (try encoder.encode(binding)) + Data(",".utf8)
            + (try encoder.encode(result)).dropFirst()
        encoded.append(10)
        try encoded.write(to: URL(fileURLWithPath: reportPath), options: [.withoutOverwriting])
        print(String(decoding: encoded, as: UTF8.self), terminator: "")
        return result.modelsReleased.allSatisfy { $0 } ? 0 : 2
    }
}
