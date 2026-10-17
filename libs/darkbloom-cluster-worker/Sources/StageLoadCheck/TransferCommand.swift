import DarkbloomClusterRuntime
import Foundation

// One Mac, one rank, the real artifact, no collective: loads the rank's stage
// from local files, then again the way a receiving rank gets it (metadata from
// the pinned content inventory, bytes from a sender core over this Mac's
// verified artifact, in this process), and compares the two. With --fault the
// sender is wrong in one way and the load must be refused and released.
//
//   env DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128 DARKBLOOM_BF16_WEIGHTS=1 MLX_ENABLE_TF32=1 \
//     darkbloom-cluster-stage-check transfer --model-dir /ABS/MODEL --rank 1 --stage-cut 4 \
//     [--fault flipped-bit|swapped-tensors|truncated-piece] [--hash-threads 1...16]
//
// Exit status 0 only if the receipt's `passed` is true.

enum TransferCommand {
    static let name = "transfer"

    static func run(_ arguments: [String]) throws -> Int32 {
        let fields = try StageCheckArguments.parse(arguments, allowed: ["--model-dir", "--rank", "--stage-cut", "--fault", "--hash-threads", "--deadline-seconds"])
        let fault = fields["--fault"].flatMap(QwenResidentStageTransferCheck.Fault.init(rawValue:))
        let threads = fields["--hash-threads"].flatMap(Int.init)
        guard let path = fields["--model-dir"], path.hasPrefix("/"),
              let rank = fields["--rank"].flatMap(Int.init), (0...1).contains(rank),
              let cut = fields["--stage-cut"].flatMap(Int.init), (fields["--fault"] == nil) == (fault == nil),
              (fields["--hash-threads"] == nil) == (threads == nil),
              let seconds = Int(fields["--deadline-seconds"] ?? "240"), (10...300).contains(seconds) else {
            throw StageLoadCheck.Failure("usage: transfer --model-dir /ABS/PATH --rank 0|1 --stage-cut CUT "
                + "[--fault flipped-bit|swapped-tensors|truncated-piece] [--hash-threads 1...16] [--deadline-seconds 10...300]")
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds) * 1_000_000_000
        let receipt = try QwenResidentStageTransferCheck.run(modelDirectory: URL(fileURLWithPath: path),
            rank: rank, stageCut: cut, deadlineUptimeNanoseconds: deadline, hashThreads: threads, fault: fault)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(receipt), as: UTF8.self))
        return receipt.passed ? 0 : 2
    }
}
