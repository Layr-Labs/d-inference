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
            // A leading mode name selects that mode; the stage load check itself has none.
            if CommandLine.arguments.dropFirst().first == ContentInventoryCommand.name {
                Darwin.exit(try ContentInventoryCommand.run(Array(CommandLine.arguments.dropFirst(2))))
            }
            if CommandLine.arguments.dropFirst().first == TransferCommand.name {
                Darwin.exit(try TransferCommand.run(Array(CommandLine.arguments.dropFirst(2))))
            }
            if CommandLine.arguments.dropFirst().first == ExpertLayoutCommand.name {
                Darwin.exit(try ExpertLayoutCommand.run(Array(CommandLine.arguments.dropFirst(2))))
            }
            let fields = try StageCheckArguments.parse(Array(CommandLine.arguments.dropFirst()),
                allowed: ["--model-dir", "--rank", "--stage-cut", "--deadline-seconds", "--hold-seconds"])
            guard let path = fields["--model-dir"], path.hasPrefix("/"),
                  let rank = fields["--rank"].flatMap(Int.init), (0...1).contains(rank),
                  let cut = fields["--stage-cut"].flatMap(Int.init),
                  let seconds = Int(fields["--deadline-seconds"] ?? "240"), (10...300).contains(seconds),
                  let hold = Int(fields["--hold-seconds"] ?? "0"), (0...240).contains(hold), hold < seconds else {
                throw Failure("usage: --model-dir /ABS/PATH --rank 0|1 --stage-cut CUT [--deadline-seconds 10...300] [--hold-seconds 0...240]\n"
                    + "  CUT is one of the registered model's cuts: 4|8|12|16 for the 9B, 4|8|...|60 for the 27B,\n"
                    + "  6|8|10|12 for GPT-OSS 20B (whose arithmetic environment is MLX_ENABLE_TF32=1 and no DARKBLOOM_GPTOSS_* switch)\n"
                    + "  --hold-seconds keeps the loaded stage that long before release (less than the deadline)")
            }
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds) * 1_000_000_000
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            // The artifact's own configuration selects the adapter that loads it.
            let configuration = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("config.json"))
            if let configuration, GPTOSSResidentStageLoadCheck.handles(configuration: configuration) {
                let receipt = try GPTOSSResidentStageLoadCheck.run(modelDirectory: URL(fileURLWithPath: path),
                    rank: rank, stageCut: cut, deadlineUptimeNanoseconds: deadline, holdSeconds: hold)
                print(String(decoding: try encoder.encode(receipt), as: UTF8.self))
                Darwin.exit(receipt.modelReleased ? 0 : 2)
            }
            let receipt = try QwenResidentStageLoadCheck.run(modelDirectory: URL(fileURLWithPath: path),
                rank: rank, stageCut: cut, deadlineUptimeNanoseconds: deadline, holdSeconds: hold)
            print(String(decoding: try encoder.encode(receipt), as: UTF8.self))
            Darwin.exit(receipt.modelReleased ? 0 : 2)
        } catch let failure as QwenResidentReleasedFailure {
            // A load that began and failed: the failure and what was still held
            // after release go to standard output as one record, like a receipt.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let record = try? encoder.encode(failure) { print(String(decoding: record, as: UTF8.self)) }
            FileHandle.standardError.write(Data("darkbloom-cluster-stage-check: \(failure)\n".utf8))
            Darwin.exit(1)
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
