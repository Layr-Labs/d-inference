import Foundation

@main struct MemoryCheck {
    static func main() throws {
        var groups = [String]()
        func run(_ name: String, _ body: () throws -> Void) throws { try body(); groups.append(name) }
        let id = identity(prompt: 8192, chunk: 256, output: 128)
        try run("actual host bound and C256 event geometry") {
            let b = try QwenGenerationPhaseBudget.derive(identity: id, hostAllocationBound: QwenGenerationPhaseHostAllocation.bound)
            try require(b.maximumEvents == 544 && b.memoryLogicalBytes == 320 * MemoryLayout<QwenResidentMemorySample>.stride,
                        "Closed event/memory geometry")
            let r = try memoryRecorder()
            try require(r.hostReservationBytes == b.requiredHostReservationBytes, "Host charge differs")
            try require(b.requiredHostReservationBytes == b.eventAllocationBytes + b.memoryAllocationBytes
                + b.encodedResultAllocationBytes + b.encodingScratchAllowanceBytes + b.metadataAllowanceBytes,
                "Complete host reservation")
        }
        try run("ordered load ready request retirement") {
            let r = try memoryRecorder(); try memoryReady(r); try r.bind(id)
            try r.append(memorySample(.requestBegin, at: 2_000_000_001))
            try r.append(memorySample(.requestLive, at: 3_000_000_001))
            try r.append(memorySample(.requestRetired, at: 3_000_000_011))
            let trace = try r.retire()
            try require(trace.samples.count == 6 && trace.readyUptimeNanoseconds == 1_000_000_020,
                        "Complete local trace")
            let afterRetirement = try r.wants(.requestLive, now: 4_000_000_001)
            try require(!afterRetirement, "Publication still records")
            try rejects("retire twice") { _ = try r.retire() }
            try rejects("second request") { try r.bind(id) }
        }
        try run("identity and geometry stay closed") {
            let r = try memoryRecorder(); try memoryReady(r)
            try rejects("wrong rank") { try r.bind(identity(rank: 1, prompt: 8192, chunk: 256, output: 128)) }
            try rejects("old C512 not silently accepted") { try r.bind(identity(prompt: 8192, chunk: 512, output: 128)) }
        }
        try run("actual readiness and retirement are required") {
            let r = try memoryRecorder()
            try rejects("no Ready") { try r.bind(id) }
            try rejects("no load") { try r.append(memorySample(.loadedRequestGuard, at: 1)) }
            try rejects("no retirement") { _ = try r.retire() }
        }
        try run("cadence and sample clock order") {
            let r = try memoryRecorder()
            try r.append(memorySample(.load, at: 1, reads: 0, total: 10))
            let early = try r.wants(.load, now: 500_000_001)
            let due = try r.wants(.load, now: 1_000_000_001)
            try require(!early, "Too frequent sample")
            try require(due, "Missing due sample")
            try rejects("clock reversal") { _ = try r.wants(.load, now: 0) }
            try rejects("direct too frequent append") {
                try r.append(memorySample(.load, at: 500_000_001, reads: 1, total: 10))
            }
        }
        try run("same selected tensor progress") {
            let r = try memoryRecorder()
            try r.append(memorySample(.load, at: 1, reads: 0, total: 10))
            try rejects("changed inventory") { try r.append(memorySample(.load, at: 2_000_000_001, reads: 1, total: 11)) }
            try rejects("incomplete load") { try r.append(memorySample(.loadComplete, at: 2_000_000_001, reads: 9, total: 10)) }
        }
        try run("floor remains admission not reclaimable") {
            let r = try memoryRecorder()
            try rejects("below actual-free floor") { try r.append(memorySample(.load, at: 1, reads: 0, total: 10, free: 1)) }
        }
        try run("bounded sample table") {
            let r = try memoryRecorder()
            for i in 0..<320 {
                try r.append(memorySample(.load, at: UInt64(i) * 1_000_000_000 + 1, reads: i, total: 400))
            }
            try rejects("capacity exceeded") { try r.append(memorySample(.load, at: 320_000_000_001, reads: 320, total: 400)) }
        }
        let out: [String: Any] = ["groups": groups, "count": groups.count, "modelOrNativeExecuted": false,
                                 "actualHostArrayCapacityChecked": true]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) + Data([10]))
    }
}
