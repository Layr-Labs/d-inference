import DarkbloomClusterRuntime
import Darwin
import Foundation

// One Mac, one rank, real artifact, no collective: runs the verified loader for
// that rank's layer range, then releases it and reports memory before, loaded
// and after. Run it once per rank a Mac may serve.
//
// The arithmetic environment must already be set, exactly as for the worker:
//   DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128 DARKBLOOM_BF16_WEIGHTS=1 MLX_ENABLE_TF32=1
// and, for a model with routed experts, also MLX_GATHER_QMM_EXPERT_SLICES=trust;
// for a Prism Hadamard pack, also DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC=1
// DARKBLOOM_BONSAI_F16_CONSTANT_CACHE=1, with MLX_QUANTIZED_CONSTANT_CACHE unset.

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
            if CommandLine.arguments.dropFirst().first == MiMoReferenceCommand.name {
                let status = try MiMoReferenceCommand.run(Array(CommandLine.arguments.dropFirst(2)))
                GateMeasurement.write()
                Darwin.exit(status)
            }
            let fields = try StageCheckArguments.parse(Array(CommandLine.arguments.dropFirst()),
                allowed: ["--model-dir", "--rank", "--stage-cut", "--deadline-seconds", "--hold-seconds",
                          GateMeasurement.modeArgument, GateMeasurement.outputArgument,
                          "--probe-prefill-tokens", "--probe-decode-steps", "--probe-residency"])
            // A MiMo artifact is recognised by its pinned configuration and has
            // its own, longer bound: it hashes 173 GB before it reads a tensor.
            let mimo = fields["--model-dir"].flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0 + "/config.json")) }
                .map(MiMoResidentStageLoadCheck.handles(configuration:)) ?? false
            let longest = mimo ? MiMoResidentStageLoadCheck.maximumDeadlineSeconds : 300
            guard let path = fields["--model-dir"], path.hasPrefix("/"),
                  let rank = fields["--rank"].flatMap(Int.init), (0...1).contains(rank),
                  let cut = fields["--stage-cut"].flatMap(Int.init),
                  let seconds = Int(fields["--deadline-seconds"] ?? "240"), (10...longest).contains(seconds),
                  let hold = Int(fields["--hold-seconds"] ?? "0"), (0...240).contains(hold), hold < seconds else {
                throw Failure("usage: --model-dir /ABS/PATH --rank 0|1 --stage-cut CUT [--deadline-seconds 10...300] [--hold-seconds 0...240]\n"
                    + "  CUT is one of the registered model's cuts (GPT-OSS's arithmetic environment is\n"
                    + "  MLX_ENABLE_TF32=1 and no DARKBLOOM_GPTOSS_* switch):\n    "
                    + (QwenResidentCapabilityMetadata.registeredCutsUsage + "\n" + GPTOSSResidentCapabilityMetadata.registeredCutsUsage)
                        .replacingOccurrences(of: "\n", with: "\n    ") + "\n"
                    + "  " + MiMoResidentStageLoadCheck.supportedCutsDescription
                    + " (deadline up to \(MiMoResidentStageLoadCheck.maximumDeadlineSeconds) s)\n"
                    + "  --hold-seconds keeps the loaded stage that long before release (less than the deadline)\n"
                    + "  " + GateMeasurement.usage)
            }
            try GateMeasurement.configure(fields)
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds) * 1_000_000_000
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let released: Bool
            let probeNames = ["--probe-prefill-tokens", "--probe-decode-steps", "--probe-residency"]
            guard mimo || probeNames.allSatisfy({ fields[$0] == nil }) else {
                throw Failure("The stage probe exists for the MiMo adapter only")
            }
            // The artifact's own configuration selects the adapter that loads it.
            let configuration = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("config.json"))
            if mimo {
                // All three or none: a probe is never half-specified.
                var probe: MiMoResidentStageLoadCheck.Probe?
                if probeNames.contains(where: { fields[$0] != nil }) {
                    guard let tokens = fields["--probe-prefill-tokens"].flatMap(Int.init),
                          let steps = fields["--probe-decode-steps"].flatMap(Int.init),
                          let residency = fields["--probe-residency"], ["on", "off"].contains(residency) else {
                        throw Failure("A stage probe needs --probe-prefill-tokens N --probe-decode-steps N --probe-residency on|off")
                    }
                    probe = try .init(prefillTokens: tokens, decodeSteps: steps, residency: residency == "on")
                }
                let receipt = try MiMoResidentStageLoadCheck.run(modelDirectory: URL(fileURLWithPath: path),
                    rank: rank, stageCut: cut, deadlineUptimeNanoseconds: deadline, holdSeconds: hold, probe: probe)
                print(String(decoding: try encoder.encode(receipt), as: UTF8.self))
                released = receipt.modelReleased
            } else if let configuration, GPTOSSResidentStageLoadCheck.handles(configuration: configuration) {
                let receipt = try GPTOSSResidentStageLoadCheck.run(modelDirectory: URL(fileURLWithPath: path),
                    rank: rank, stageCut: cut, deadlineUptimeNanoseconds: deadline, holdSeconds: hold)
                print(String(decoding: try encoder.encode(receipt), as: UTF8.self))
                released = receipt.modelReleased
            } else {
                let receipt = try QwenResidentStageLoadCheck.run(modelDirectory: URL(fileURLWithPath: path),
                    rank: rank, stageCut: cut, deadlineUptimeNanoseconds: deadline, holdSeconds: hold)
                print(String(decoding: try encoder.encode(receipt), as: UTF8.self))
                released = receipt.modelReleased
            }
            GateMeasurement.write()
            Darwin.exit(released ? 0 : 2)
        } catch let failure as QwenResidentReleasedFailure {
            // A load that began and failed: the failure and what was still held
            // after release go to standard output as one record, like a receipt.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let record = try? encoder.encode(failure) { print(String(decoding: record, as: UTF8.self)) }
            FileHandle.standardError.write(Data("darkbloom-cluster-stage-check: \(failure)\n".utf8))
            GateMeasurement.write()
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
