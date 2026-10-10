import DarkbloomClusterRuntime
import Foundation

// One Mac, the real GPT-OSS artifact, no model and no collective: compares the
// experts as a stage holds them (stored gate and up projections, separate)
// with the product's load-time layout (one concatenated projection), byte for
// byte, on the stored bytes of the chosen layers.
//
//   env MLX_ENABLE_TF32=1 darkbloom-cluster-stage-check expert-layout \
//     --model-dir /ABS/MODEL [--layers 0,11,23] [--chunk-tokens 512]
//
// Exit status 0 when every output is bit-identical, 3 when one is not.

enum ExpertLayoutCommand {
    static let name = "expert-layout"

    static func run(_ arguments: [String]) throws -> Int32 {
        let fields = try StageCheckArguments.parse(arguments,
            allowed: ["--model-dir", "--layers", "--chunk-tokens", "--deadline-seconds"])
        let layers = (fields["--layers"] ?? "0,11,23").split(separator: ",").map { Int($0) }
        guard let model = fields["--model-dir"], model.hasPrefix("/"), !layers.contains(nil),
              let chunk = Int(fields["--chunk-tokens"] ?? "512"),
              let seconds = Int(fields["--deadline-seconds"] ?? "240"), (10...300).contains(seconds) else {
            throw StageLoadCheck.Failure("usage: expert-layout --model-dir /ABS/PATH [--layers A,B,...] "
                + "[--chunk-tokens 64...512] [--deadline-seconds 10...300]")
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds) * 1_000_000_000
        let report = try GPTOSSExpertLayoutCheck.run(modelDirectory: URL(fileURLWithPath: model),
            layers: layers.compactMap { $0 }, chunkTokens: chunk, deadlineUptimeNanoseconds: deadline)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
        return report.everyOutputBitIdentical ? 0 : 3
    }
}
