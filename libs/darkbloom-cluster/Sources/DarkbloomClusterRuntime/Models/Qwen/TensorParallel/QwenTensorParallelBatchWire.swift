import Foundation

/// Exact control words carried by the TP group's authenticated all-sum. Each
/// rank owns one disjoint region; splitting Int32 into two UInt16 limbs keeps
/// UUIDs, fingerprints and checksums exact in FP32. The load agreement binds
/// this protocol separately from the pipeline protocol it uses for framing.
enum QwenTensorParallelBatchWire {
    static let agreement = "qwen-tp-independent-history-batch-v1"
    static let words = 4 + 2 * (QwenBatchWire.headerWords + QwenBatchWire.replyWords)
    private static let magic: Float = 0x515442

    static func contribution(rank: Int, plan: QwenBatchWire.Header?, report: QwenBatchWire.Reply?) throws -> [Float] {
        guard (rank == 0 && plan != nil && report == nil) || (rank == 1 && plan == nil && report != nil) else {
            throw ProbeError("Qwen TP batch contribution belongs to the other rank")
        }
        var result = [Float](repeating: 0, count: words)
        result[rank * 2] = magic; result[rank * 2 + 1] = 1
        let offset = 4 + (rank == 0 ? 0 : 2 * QwenBatchWire.headerWords)
        for (index, value) in (plan?.words ?? report!.words).enumerated() {
            let bits = UInt32(bitPattern: value)
            result[offset + 2 * index] = Float(bits & 0xffff)
            result[offset + 2 * index + 1] = Float(bits >> 16)
        }
        return result
    }

    static func read(_ sum: [Float], step: Int, lanes: Int) throws -> (QwenBatchWire.Header, QwenBatchWire.Reply) {
        guard (1...8).contains(lanes), sum.count == words,
              Array(sum.prefix(4)) == [magic, 1, magic, 1] else {
            throw ProbeError("Qwen TP batch control message has a wrong membership or length")
        }
        var values: [Int32] = []
        for index in stride(from: 4, to: sum.count, by: 2) {
            let low = sum[index], high = sum[index + 1]
            guard low.isFinite, high.isFinite, low.rounded() == low, high.rounded() == high,
                  (0...65535).contains(low), (0...65535).contains(high) else {
                throw ProbeError("Qwen TP batch control message has an inexact word")
            }
            values.append(Int32(bitPattern: UInt32(low) | (UInt32(high) << 16)))
        }
        let plan = try QwenBatchWire.Header(words: Array(values.prefix(QwenBatchWire.headerWords)), expectedStep: step, lanes: lanes)
        let report = try QwenBatchWire.Reply(words: Array(values.suffix(QwenBatchWire.replyWords)), expectedStep: step, lanes: lanes)
        guard report.tokens.allSatisfy({ $0 >= -1 }), report.restored.allSatisfy({ $0 == 0 }),
              plan.slots.allSatisfy({ !$0.confirming && $0.offers.isEmpty && $0.reusedPrefix == 0 }),
              !plan.stop || plan.slots.allSatisfy({ $0.state == .empty }) else {
            throw ProbeError("Qwen TP batch control message requests an unsupported transition")
        }
        return (plan, report)
    }
}
