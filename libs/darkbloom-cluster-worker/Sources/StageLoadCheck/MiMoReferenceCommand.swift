import CryptoKit
import DarkbloomClusterRuntime
import Darwin
import Foundation

/// `darkbloom-cluster-stage-check mimo-reference`: one Mac, both MiMo stages
/// of one cut in one process, one qualification request through them. The
/// single-Mac reference a pair's tokens are compared with. It needs a Mac that
/// can hold the whole text model (156 GiB of tensors).
enum MiMoReferenceCommand {
    /// `QualificationHost`'s fields, read the same way (this tool does not link the qualification package).
    struct Host: Encodable {
        let role = "single host"
        let chip: String?
        let operatingSystem: String
        static func local() -> Host {
            var size = 0
            var chip: String?
            if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1, size <= 256 {
                var bytes = [CChar](repeating: 0, count: size)
                if sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 {
                    chip = String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return .init(chip: chip, operatingSystem: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        }
    }

    /// The request fields a pair's qualification identity compares, so a
    /// record binds this reference to the request the pair ran
    /// (`MiMoQualificationEvidence.RequestBinding`): the prompt's digest in
    /// the runtime's token-history convention (decimal IDs joined by commas,
    /// `QualificationHash.tokenIDs`), the chunk, the outputs and the stops.
    struct RequestBinding: Encodable {
        let promptTokenIDsSHA256: String
        let chunkSize: Int, outputCount: Int, stopTokenIDs: [Int]
        init(promptTokenIDs: [Int], chunkSize: Int, outputCount: Int, stopTokenIDs: [Int]) {
            promptTokenIDsSHA256 = SHA256.hash(data: Data(promptTokenIDs.map(String.init).joined(separator: ",").utf8))
                .map { String(format: "%02x", $0) }.joined()
            self.chunkSize = chunkSize; self.outputCount = outputCount; self.stopTokenIDs = stopTokenIDs
        }
    }

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
        // The report names the kind of Mac that ran it (its chip and system
        // version, never a host name), as every single-Mac reference does:
        // a qualification record lists each reference's chip.
        // It also names the request it ran, so a record compares the prompt,
        // chunk, outputs and stops with the pair's instead of trusting the ID.
        let binding = RequestBinding(promptTokenIDs: file.promptTokenIDs, chunkSize: file.chunkSize,
                                     outputCount: file.outputCount, stopTokenIDs: file.stopTokenIDs)
        var encoded = Data("{\"host\":".utf8) + (try encoder.encode(Host.local()))
            + Data(",\"request\":".utf8) + (try encoder.encode(binding)) + Data(",".utf8)
            + (try encoder.encode(result)).dropFirst()
        encoded.append(10)
        try encoded.write(to: URL(fileURLWithPath: reportPath), options: [.withoutOverwriting])
        print(String(decoding: encoded, as: UTF8.self), terminator: "")
        return result.modelsReleased.allSatisfy { $0 } ? 0 : 2
    }
}
