import DarkbloomClusterRuntime
import Darwin
import Foundation

// One Mac, one rank, real artifact, no collective: runs the verified loader for
// that rank's layer range, then releases it and reports memory before, loaded
// and after. Run it once per rank a Mac may serve.
//
// The arithmetic environment must already be set, exactly as for the worker:
//   DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128 DARKBLOOM_BF16_WEIGHTS=1 MLX_ENABLE_TF32=1

@main enum StageLoadCheck {
    static func main() {
        do {
            var fields: [String: String] = [:]
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count % 2 == 0 else { throw Failure("Expected --name value pairs") }
            for index in stride(from: 0, to: arguments.count, by: 2) {
                guard ["--model-dir", "--rank", "--stage-cut", "--deadline-seconds"].contains(arguments[index]),
                      fields[arguments[index]] == nil else {
                    throw Failure("Unknown or repeated argument \(arguments[index])")
                }
                fields[arguments[index]] = arguments[index + 1]
            }
            guard let path = fields["--model-dir"], path.hasPrefix("/"),
                  let rank = fields["--rank"].flatMap(Int.init), (0...1).contains(rank),
                  let cut = fields["--stage-cut"].flatMap(Int.init),
                  let seconds = Int(fields["--deadline-seconds"] ?? "240"), (10...300).contains(seconds) else {
                throw Failure("usage: --model-dir /ABS/PATH --rank 0|1 --stage-cut 4|8|12|16 [--deadline-seconds 10...300]")
            }
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds) * 1_000_000_000
            let receipt = try QwenResidentStageLoadCheck.run(modelDirectory: URL(fileURLWithPath: path),
                rank: rank, stageCut: cut, deadlineUptimeNanoseconds: deadline)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(receipt), as: UTF8.self))
            Darwin.exit(receipt.modelReleased ? 0 : 2)
        } catch {
            FileHandle.standardError.write(Data("darkbloom-cluster-stage-check: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
