import Foundation

@main struct EncodingCheck {
    static func main() throws {
        var sizes = [Int](), groups = [String]()
        func run(_ name: String, _ body: () throws -> Void) throws { try body(); groups.append(name) }
        let bound = QwenGenerationPhaseHostAllocation.bound
        let id = identity(prompt: 8192, chunk: 274, output: 128)
        let budget = try QwenGenerationPhaseBudget.derive(identity: id, hostAllocationBound: bound)

        try run("actual host rounding and wide-field full report") {
            try require(budget.maximumEvents == 512, "Maximum event slots")
            for rank in 0...1 {
                let owner = identity(rank: rank, prompt: 8192, chunk: 274, output: 128)
                let captured = try QwenGenerationPhaseRecorder.forCPUFixture(identity: owner, budget: budget,
                    clock: { UInt64.max }, reservationCheck: {})
                try captured.begin(expected: owner)
                try captured.observe(event(.requestBegin))
                let frame = QwenGenerationPhaseFrame(sequence: 29, tokenOffset: 7946, tokenCount: 246, finalPromptChunk: true)
                for _ in 0..<(budget.maximumEvents - 2) {
                    try captured.observe(event(rank == 0 ? .originalWrapperReleased : .consumedAckSendBegin,
                        frame: frame, local: 8320, agreed: 8320))
                }
                try captured.observe(event(.requestRetired)); try captured.seal()
                let trace = try captured.successfulTrace(), hash = String(repeating: "a", count: 64)
                let session = QwenLayerStageSessionIdentity(stageIndex: rank, requestFingerprint: hash,
                    artifactAggregateSHA256: hash, storageCommitmentSHA256: hash, bf16ConversionEnabled: true,
                    sourceConfigurationSHA256: hash, constructionConfigurationSHA256: hash,
                    planFingerprint: hash, stageFingerprint: hash, activationDType: "bfloat16")
                let execution = QwenLayerStageGenerationResult(agreementFingerprint: hash,
                    membershipEpoch: owner.membershipEpoch, identity: session, selectedTokenIDs: Array(248192..<248320),
                    tokenChainSHA256: hash, completedFrames: 143, committedTokens: 8319, finishReason: .length)
                let writer = try QwenGenerationPhaseJSON(budget: budget)
                try QwenGenerationPhaseEncoding.encode(trace: trace, budget: budget, execution: execution,
                    totalReserved: Int.max, liveChecks: Int.max, into: writer)
                try writer.publish { bytes in
                    let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                    let events = object["events"] as! [[String: Any]]
                    try require(events.count == 512, "Missing bounded event rows")
                    try require((events[0]["localUptimeNanoseconds"] as! NSNumber).uint64Value == UInt64.max, "Timestamp narrowed")
                    try require((object["execution"] as! [String: Any])["selectedTokenIDs"] as! [Int] == execution.selectedTokenIDs,
                        "Token IDs changed while encoding")
                    try require(bytes.count <= QwenGenerationPhaseBudget.maximumEncodedBytes, "Output cap")
                    sizes.append(bytes.count)
                }
                try rejects("output transferred twice") { try writer.publish { _ in } }
            }
        }
        try run("fixed output refusal and unsafe JSON strings") {
            let writer = try QwenGenerationPhaseJSON(budget: budget)
            for _ in 0..<256 { try writer.raw(String(repeating: "a", count: 1024)) }
            try rejects("one byte beyond allocation") { try writer.raw("b") }
            let other = try QwenGenerationPhaseJSON(budget: budget)
            try rejects("unescaped quote") { try other.string("\"") }
            try rejects("unescaped slash") { try other.string("\\") }
            try rejects("string length") { try other.string(String(repeating: "a", count: 1025)) }
        }
        try run("actual retained output is refused") {
            var retained: Data?
            let writer = try QwenGenerationPhaseJSON(budget: budget)
            for _ in 0..<64 { try writer.raw(String(repeating: "a", count: 1024)) }
            try rejects("retained publisher buffer") { try writer.publish { retained = $0 } }
            try require(retained?.count == 65536, "Retention fixture did not hold the actual Data")
            retained = nil
        }
        try run("publisher failure preserves original error") {
            let writer = try QwenGenerationPhaseJSON(budget: budget)
            try writer.raw(String(repeating: "a", count: 1024))
            do { try writer.publish { _ in throw FixtureFailure.native }; throw FixtureFailure.assertion("Missing publisher failure") }
            catch FixtureFailure.native { }
        }
        try run("actual sidecar checks keep the resource gate live") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let sink = try ResidentEvidenceSink(path: directory.path), id = UUID()
            let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
            var calls = 0
            try rejects("live resource failure during sidecar output") {
                try sink.publish(Data(repeating: 1, count: 131072), requestID: id, deadline: deadline) {
                    calls += 1
                    if calls == 3 { throw FixtureFailure.reservation }
                }
            }
            try require(calls == 3, "Writer did not recheck between bounded chunks")
            let path = directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
            let partial = try Data(contentsOf: path)
            try require(partial.count == 65536, "Failed partial evidence not retained")
            try rejects("failed sidecar UUID cannot overwrite") {
                try sink.publish(Data([1]), requestID: id, deadline: deadline)
            }
        }
        let result: [String: Any] = ["groups": groups, "count": groups.count, "encodedBytes": sizes,
            "modelOrNativeExecuted": false, "actualHostMallocAndLocalSidecarIO": true,
            "nativeResourceAdmissionProved": false]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) + Data([10]))
    }
}
