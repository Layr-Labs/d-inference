import DarkbloomClusterProtocol
import Foundation

/// The one message of each step of the GLM tensor-parallel lane loop, carried
/// by the step's one sealed all-sum (`QwenTensorParallelGroup.allSum`): rank 0
/// writes its plan into the first region and zeros into the second, rank 1
/// writes zeros into the first and its own report into the second, so the sum
/// is both, exactly (every word is an integer below 2^24 in magnitude, exact in
/// float32, added to zero). The sum is sealed (authenticated) on a keyed data
/// plane; the step number, lane count and per-region checksums still stop both
/// ranks at a message from another step or a desynchronized peer instead of
/// letting them run different graphs.
///
/// The plan names, per slot, the lane that holds it (its request ID), what it
/// does this step (join, one prefill frame, one decode unit, leave) and the
/// agreed facts rank 1 checks against its own lane (tokens agreed, the decode
/// unit's input token and window, the frame's bounds and the layers of its
/// slice this step runs). Rank 1's report carries
/// what only it knows: a lane its own owner cancelled or whose deadline passed
/// here, which rank 0 then plans to leave.
enum GLM5NextTensorParallelLaneWire {
    /// Lanes one loop serves at most (the worker protocol's lane cap).
    static let maximumLanes = QwenBatchWire.maximumLanes
    static let planMagic = 0x474C_31   // "GL1"
    static let reportMagic = 0x474C_32 // "GL2"
    static let version = 2
    static let headWords = 8
    static let slotWords = 20
    static let reportHeadWords = 6
    static let reportSlotWords = 2
    /// Words are integers strictly inside this bound (exact in float32).
    static let wordBound = 1 << 24

    static func wordCount(lanes: Int) -> Int {
        headWords + lanes * slotWords + reportHeadWords + lanes * reportSlotWords
    }

    enum SlotState: Int { case empty = 0, joining = 1, active = 2, leaving = 3 }
    enum Role: Int { case none = 0, decode = 1, prefill = 2 }
    /// Why a lane leaves. A finish is rank 0's decision from the owner's
    /// answers (`QwenTensorParallelStopRule`); `cancelled` retires the lane
    /// without a finish (its owner cancelled it or its deadline passed).
    enum Leave: Int, Equatable {
        case eos = 1, length = 2, clientStop = 3, cancelled = 4

        init(_ finish: ClusterWorkerFinishReason) {
            switch finish {
            case .eos: self = .eos
            case .length: self = .length
            case .clientStop: self = .clientStop
            }
        }
        var finish: ClusterWorkerFinishReason? {
            switch self {
            case .eos: .eos
            case .length: .length
            case .clientStop: .clientStop
            case .cancelled: nil
            }
        }
    }

    /// A prefill frame `offset ..< end` of a lane's prompt (`final`: it ends
    /// the prompt), or the slice of it this step runs: its stage layers
    /// `layers`; `finishes` when they are the frame's last (the frame then
    /// commits, and a final frame agrees the lane's first token).
    struct Frame: Equatable {
        let offset: Int
        let end: Int
        let final: Bool
        let layers: Range<Int>
        let finishes: Bool
    }

    struct Slot: Equatable {
        var state: SlotState = .empty
        var requestID: UUID?
        var role: Role = .none
        /// Agreed tokens of the lane before this step.
        var tokens = 0
        /// A decode unit: the token it decodes after, and its MTP window
        /// (proposals verified; nil for a one-token step).
        var last = -1
        var window: Int?
        /// A prefill frame.
        var frame: Frame?
        /// A leaving lane: why, and how many agreed tokens it keeps.
        var leave: Leave?
        var kept = 0
    }

    /// Rank 0's region.
    struct Plan: Equatable {
        var step: Int
        /// No lane is left: both ranks leave the loop after this message.
        var stop: Bool
        var lanes: Int
        var depth: Int
        var prefixEnabled: Bool
        var slots: [Slot]
    }

    /// Rank 1's region.
    struct Report: Equatable {
        var step: Int
        var lanes: Int
        var prefixEnabled: Bool
        /// Per slot: rank 1 wants the lane there to leave (cancelled or past
        /// its deadline on this rank).
        var leaveWanted: [Bool]
        /// Per slot: rank 1's agreed tokens of the lane there, nil when the
        /// slot is empty on rank 1.
        var tokens: [Int?]
    }

    /// 24-bit FNV-1a over a region's words, so it is itself a word.
    static func checksum(_ words: ArraySlice<Int>) -> Int {
        var hash: UInt32 = 0x811C_9DC5
        for word in words {
            var value = UInt32(truncatingIfNeeded: word)
            for _ in 0..<4 { hash = (hash ^ (value & 0xFF)) &* 0x0100_0193; value >>= 8 }
        }
        return Int(hash & 0xFF_FFFF)
    }

    static func idWords(_ id: UUID) -> [Int] {
        let u = id.uuid
        let bytes = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        return (0..<8).map { Int(bytes[2 * $0]) << 8 | Int(bytes[2 * $0 + 1]) }
    }

    static func id(_ words: ArraySlice<Int>) -> UUID {
        let w = Array(words)
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { b[2 * i] = UInt8((w[i] >> 8) & 0xFF); b[2 * i + 1] = UInt8(w[i] & 0xFF) }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Rank 0's contribution: the plan, zeros where rank 1 reports.
    static func words(_ plan: Plan) throws -> [Float] {
        guard (1...maximumLanes).contains(plan.lanes), plan.slots.count == plan.lanes else {
            throw ProbeError("GLM lane plan has a wrong lane count")
        }
        var w = [Int](repeating: 0, count: wordCount(lanes: plan.lanes))
        w[0] = planMagic; w[1] = version; w[2] = plan.step % wordBound; w[3] = plan.stop ? 1 : 0
        w[4] = plan.lanes; w[5] = plan.depth; w[6] = plan.prefixEnabled ? 1 : 0
        for (index, slot) in plan.slots.enumerated() {
            let base = headWords + index * slotWords
            w[base] = slot.state.rawValue
            if let id = slot.requestID { w.replaceSubrange((base + 1)...(base + 8), with: idWords(id)) }
            w[base + 9] = slot.role.rawValue
            w[base + 10] = slot.tokens
            w[base + 11] = slot.last + 1
            w[base + 12] = slot.window.map { $0 + 1 } ?? 0
            w[base + 13] = slot.frame?.offset ?? 0
            w[base + 14] = slot.frame?.end ?? 0
            w[base + 15] = slot.frame.map { ($0.final ? 1 : 0) + ($0.finishes ? 2 : 0) } ?? 0
            w[base + 16] = slot.leave?.rawValue ?? 0
            w[base + 17] = slot.kept
            w[base + 18] = slot.frame?.layers.lowerBound ?? 0
            w[base + 19] = slot.frame?.layers.upperBound ?? 0
        }
        let end = headWords + plan.lanes * slotWords
        w[7] = checksum(w[0..<7] + w[headWords..<end])
        return try floats(w)
    }

    /// Rank 1's contribution: zeros where rank 0 plans, the report.
    static func words(_ report: Report) throws -> [Float] {
        guard (1...maximumLanes).contains(report.lanes), report.leaveWanted.count == report.lanes,
              report.tokens.count == report.lanes else {
            throw ProbeError("GLM lane report has a wrong lane count")
        }
        var w = [Int](repeating: 0, count: wordCount(lanes: report.lanes))
        let base = headWords + report.lanes * slotWords
        w[base] = reportMagic; w[base + 1] = report.step % wordBound; w[base + 2] = report.lanes
        w[base + 3] = report.prefixEnabled ? 1 : 0
        for index in 0..<report.lanes {
            let slot = base + reportHeadWords + index * reportSlotWords
            w[slot] = report.leaveWanted[index] ? 1 : 0
            w[slot + 1] = report.tokens[index].map { $0 + 1 } ?? 0
        }
        w[base + 5] = checksum(w[base..<(base + 5)] + w[(base + reportHeadWords)...])
        return try floats(w)
    }

    /// Both regions of the summed message, checked: the step and lane count
    /// both ranks expect, each region's magic and checksum, every word an
    /// integer in its range.
    static func read(_ summed: [Float], lanes: Int, step: Int) throws -> (plan: Plan, report: Report) {
        guard (1...maximumLanes).contains(lanes), summed.count == wordCount(lanes: lanes) else {
            throw ProbeError("GLM lane message has a wrong length")
        }
        let w = try summed.map { value -> Int in
            guard value.isFinite, value.rounded() == value, abs(value) < Float(wordBound) else {
                throw ProbeError("GLM lane message carries a word that is not an exact integer")
            }
            return Int(value)
        }
        let end = headWords + lanes * slotWords
        guard w[0] == planMagic, w[1] == version, w[2] == step % wordBound, [0, 1].contains(w[3]),
              w[4] == lanes, w[5] >= 0, [0, 1].contains(w[6]),
              w[7] == checksum(w[0..<7] + w[headWords..<end]) else {
            throw ProbeError("GLM lane plan from rank 0 is malformed or from another step")
        }
        var slots: [Slot] = []
        for index in 0..<lanes {
            let base = headWords + index * slotWords
            guard let state = SlotState(rawValue: w[base]), let role = Role(rawValue: w[base + 9]),
                  w[base + 10] >= 0, w[base + 11] >= 0, w[base + 12] >= 0, w[base + 13] >= 0,
                  w[base + 14] >= w[base + 13], (0...3).contains(w[base + 15]), (0...4).contains(w[base + 16]),
                  w[base + 17] >= 0, w[base + 18] >= 0, w[base + 19] >= w[base + 18] else {
                throw ProbeError("GLM lane plan slot is malformed")
            }
            var slot = Slot(state: state, requestID: state == .empty ? nil : id(w[(base + 1)...(base + 8)]), role: role)
            slot.tokens = w[base + 10]; slot.last = w[base + 11] - 1
            slot.window = w[base + 12] == 0 ? nil : w[base + 12] - 1
            if role == .prefill {
                guard w[base + 14] > w[base + 13], w[base + 19] > w[base + 18] else {
                    throw ProbeError("GLM lane plan has an empty prefill frame or slice")
                }
                slot.frame = Frame(offset: w[base + 13], end: w[base + 14], final: w[base + 15] & 1 == 1,
                    layers: w[base + 18] ..< w[base + 19], finishes: w[base + 15] & 2 == 2)
            }
            slot.leave = w[base + 16] == 0 ? nil : Leave(rawValue: w[base + 16])
            slot.kept = w[base + 17]
            guard (state == .leaving) == (slot.leave != nil), role == .none || state == .active,
                  role != .decode || slot.last >= 0 else {
                throw ProbeError("GLM lane plan slot state, role and leave disagree")
            }
            slots.append(slot)
        }
        let plan = Plan(step: step, stop: w[3] == 1, lanes: lanes, depth: w[5], prefixEnabled: w[6] == 1, slots: slots)
        guard !plan.stop || slots.allSatisfy({ $0.state == .empty || $0.state == .leaving }) else {
            throw ProbeError("GLM lane plan stops with lanes still running")
        }
        let base = end
        guard w[base] == reportMagic, w[base + 1] == step % wordBound, w[base + 2] == lanes,
              [0, 1].contains(w[base + 3]), w[base + 4] == 0,
              w[base + 5] == checksum(w[base..<(base + 5)] + w[(base + reportHeadWords)...]) else {
            throw ProbeError("GLM lane report from rank 1 is malformed or from another step")
        }
        var wanted: [Bool] = [], tokens: [Int?] = []
        for index in 0..<lanes {
            let slot = base + reportHeadWords + index * reportSlotWords
            guard [0, 1].contains(w[slot]), w[slot + 1] >= 0 else { throw ProbeError("GLM lane report slot is malformed") }
            wanted.append(w[slot] == 1); tokens.append(w[slot + 1] == 0 ? nil : w[slot + 1] - 1)
        }
        return (plan, Report(step: step, lanes: lanes, prefixEnabled: w[base + 3] == 1, leaveWanted: wanted, tokens: tokens))
    }

    private static func floats(_ words: [Int]) throws -> [Float] {
        guard words.allSatisfy({ abs($0) < wordBound }) else {
            throw ProbeError("GLM lane message word is outside float32's exact integers")
        }
        return words.map(Float.init)
    }
}
