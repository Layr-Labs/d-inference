import Foundation

@main struct PlacementChecks {
    static func refused(_ fixture: PlacementFixture, containing text: String) throws {
        let result = try fixture.result()
        try require(result.proposals.isEmpty && result.preferredCandidateID == nil &&
                    result.refused.count == 1 && result.refused[0].reason.contains(text), text)
    }
    static func main() throws {
        let checks: [(String, () throws -> Void)] = [
            ("pipeline_overlap_and_decode_fence", {
                let result = try PlacementFixture.pipeline().result()
                let value = result.proposals[0]
                try require(value.firstTokenNanoseconds == 56 && value.decode.nanoseconds == 72 &&
                            value.steadyDecodeNanosecondsPerToken == 36 && value.totalRequestNanoseconds == 128,
                            "hand-calculated synthetic schedule")
                let a1 = value.prefill.tasks.first { $0.id == "prefill1a" }!
                let b0 = value.prefill.tasks.first { $0.id == "prefill0b" }!
                try require(a1.startNanoseconds < b0.endNanoseconds, "actual predicted prefill overlap")
                let d1 = value.decode.tasks.first { $0.id == "decode1a" }!
                try require(d1.startNanoseconds == 36, "no autoregressive overlap")
            }),
            ("charged_phase_handoff_and_separate_objectives", {
                var fixture = PlacementFixture.pipeline(); fixture.addSoloDecode()
                let total = try fixture.result(), decode = try fixture.result(.steadyDecode)
                let phased = total.proposals.first { $0.candidateID == "phase-change" }!
                try require(phased.transitionNanoseconds == 58 && phased.decode.nanoseconds == 42 &&
                            phased.totalRequestNanoseconds == 156, "load + KV + completion are charged")
                try require(total.preferredCandidateID == "pipeline" && decode.preferredCandidateID == "phase-change" &&
                            Set(total.paretoCandidateIDs) == Set(["pipeline", "phase-change"]), "phase objectives")
                let peak = phased.memory.first { $0.phase == .transition && $0.rank == 1 }!
                try require(peak.weightBytes == 300 && peak.additionalLiveBytes == 160, "union weights and both KV")
            }),
            ("handoff_absence_refuses", {
                var fixture = PlacementFixture.pipeline(); fixture.addSoloDecode()
                fixture.candidates([try replacing(fixture.request.candidates[1], "transition", NSNull())])
                try refused(fixture, containing: "explicit handoff")
            }),
            ("missing_weight_load_refuses", {
                var fixture = PlacementFixture.pipeline(); fixture.addSoloDecode()
                fixture.candidates([fixture.request.candidates[1]])
                fixture.measurements = .init(local: fixture.measurements.local.filter { $0.id != "load-wa" },
                                             links: fixture.measurements.links)
                try refused(fixture, containing: "unmeasured: load-wa")
            }),
            ("handoff_kv_payload_and_overlap_refuse", {
                for (key, replacement) in [("kvBytes0to1", 6)] {
                    var fixture = PlacementFixture.pipeline(); fixture.addSoloDecode()
                    let candidate = fixture.request.candidates[1]
                    let handoff = try replacing(candidate.transition!, key, replacement)
                    fixture.candidates([try replacing(candidate, "transition", object(handoff))])
                    try refused(fixture, containing: "KV handoff payload")
                }
                var fixture = PlacementFixture.pipeline(); fixture.addSoloDecode()
                let candidate = fixture.request.candidates[1]
                let handoff = try replacing(candidate.transition!, "memory", object([PlacementFixture.memory(), PlacementFixture.memory()]))
                fixture.candidates([try replacing(candidate, "transition", object(handoff))])
                try refused(fixture, containing: "both declared KV")
            }),
            ("actual_available_memory_and_every_live_charge", {
                var fixture = PlacementFixture.pipeline()
                try fixture.changeNode(0, "actualAvailableBytes", 369)
                try refused(fixture, containing: "requires 370 B")
                fixture = PlacementFixture.pipeline(); try fixture.changeNode(0, "actualAvailableBytes", 370)
                try require(try fixture.result().proposals.count == 1, "exact memory boundary")
                let candidate = fixture.request.candidates[0]
                let larger = try replacing(candidate.prefillMemory[0], "otherRetainedBytes", 1)
                fixture.candidates([try replacing(candidate, "prefillMemory", object([larger, candidate.prefillMemory[1]]))])
                try refused(fixture, containing: "requires 371 B")
            }),
            ("stale_ac_pressure_swap_and_floor_refuse", {
                for (key, bad) in [("ageNanoseconds", 1001), ("pressureLevel", 2), ("swapBytes", 1), ("minimumFreeBytes", 0)] {
                    var fixture = PlacementFixture.pipeline(); try fixture.changeNode(0, key, bad)
                    try mustThrow { _ = try fixture.result() }
                }
                var fixture = PlacementFixture.pipeline(); try fixture.changeNode(1, "onACPower", false)
                try mustThrow { _ = try fixture.result() }
            }),
            ("shared_weight_region_counted_once_per_node", {
                let fixture = PlacementFixture.pipeline()
                let model = PlacementModel(weights: [.init(id: "shared", bytes: 99)], operators: ["a", "b"].map {
                    .init(id: $0, fixedWeightIDs: ["shared"], expertWeightIDs: [], prefillCoverage: .everyStep, decodeCoverage: .everyStep)
                })
                let request = try replacing(fixture.request, "model", object(model))
                try PlacementValidation.request(request)
                let shape = try PlacementValidation.shape(.singleNode(0), request: request)
                try require(shape.weightBytes == [99, 0], "shared allocation identity")
            }),
            ("unequal_noncontiguous_whole_expert_ownership", {
                let fixture = PlacementFixture.pipeline()
                let weights = (0..<4).map { PlacementWeight(id: "expert\($0)", bytes: UInt64(($0 + 1) * 10)) }
                let model = PlacementModel(weights: weights, operators: [.init(id: "moe", fixedWeightIDs: [],
                    expertWeightIDs: weights.map { [$0.id] }, prefillCoverage: .everyStep, decodeCoverage: .everyStep)])
                let request = try replacing(fixture.request, "model", object(model))
                try PlacementValidation.request(request)
                let shape = try PlacementValidation.shape(.wholeExperts(["moe": .wholeExperts([[2], [3, 0, 1]])]), request: request)
                try require(shape.weightBytes == [30, 70], "whole expert planes, unequal ownership")
                try mustThrow { _ = try PlacementValidation.shape(.wholeExperts(["moe": .wholeExperts([[2], [2, 0, 1]])]), request: request) }
                try mustThrow { _ = try PlacementValidation.shape(.wholeExperts(["moe": .wholeExperts([[2], [0, 1]])]), request: request) }
            }),
            ("unmeasured_compute_or_link_refuses", {
                var fixture = PlacementFixture.pipeline()
                fixture.measurements = .init(local: Array(fixture.measurements.local.dropFirst()), links: fixture.measurements.links)
                try refused(fixture, containing: "unmeasured: prefill0a")
                fixture = PlacementFixture.pipeline(); fixture.measurements = .init(local: fixture.measurements.local, links: [])
                try refused(fixture, containing: "unmeasured: forward")
            }),
            ("calibration_workload_native_and_arithmetic_substitution", {
                for key in ["sampleSHA256", "promptTokens"] {
                    var fixture = PlacementFixture.pipeline()
                    let changed: Any = key == "sampleSHA256" ? String(repeating: "b", count: 64) : 3
                    let workload = try replacing(fixture.context.workload, key, changed)
                    let context = try replacing(fixture.context, "workload", object(workload))
                    try fixture.changeLocal(0, "context", object(context)); try refused(fixture, containing: "calibration mismatch")
                }
                for key in ["nativeBuildSHA256", "arithmeticProfile"] {
                    var fixture = PlacementFixture.pipeline()
                    let changed: Any = key == "nativeBuildSHA256" ? [String(repeating: "b", count: 64), PlacementFixture.digest] : "different"
                    let identity = try replacing(fixture.context.identity, key, changed)
                    let context = try replacing(fixture.context, "identity", object(identity))
                    try fixture.changeLocal(0, "context", object(context)); try refused(fixture, containing: "calibration mismatch")
                }
            }),
            ("ownership_and_cost_basis_substitution", {
                var fixture = PlacementFixture.pipeline()
                try fixture.changeLocal(0, "operatorPlacements", object(["a": PlacementAssignment.replicated]))
                try refused(fixture, containing: "operator/expert ownership")
                fixture = PlacementFixture.pipeline()
                let context = try replacing(fixture.context, "costBasis", "p95")
                try fixture.changeLocal(0, "context", object(context)); try refused(fixture, containing: "calibration mismatch")
            }),
            ("link_domain_direction_and_zero_rate", {
                for (key, bad) in [("minimumPlaintextBytes", 2), ("destination", 0), ("effectiveWireBytesPerSecond", 0)] {
                    var fixture = PlacementFixture.pipeline()
                    var links = fixture.measurements.links; links[0] = try replacing(links[0], key, bad)
                    fixture.measurements = .init(local: fixture.measurements.local, links: links)
                    try require(try fixture.result().proposals.isEmpty, "bad link calibration")
                }
            }),
            ("authenticated_cost_requires_actual_seal_and_open", {
                var fixture = PlacementFixture.pipeline()
                let identity = try replacing(fixture.request.identity, "transportProfile", "authenticated/fixture-v1")
                fixture.request = try replacing(fixture.request, "identity", object(identity))
                let context = fixture.context
                let local = try fixture.measurements.local.map { try replacing($0, "context", object(context)) }
                var links = try fixture.measurements.links.map { try replacing($0, "context", object(context)) }
                fixture.measurements = .init(local: local, links: links)
                try refused(fixture, containing: "missing authenticated encryption")
                let crypto = PlacementEncryptionCost.authenticated(sealBytesPerSecond: 1_000_000_000,
                    openBytesPerSecond: 1_000_000_000, fixedNanosecondsPerRecord: 4)
                links = try links.map { try replacing($0, "encryption", object(crypto)) }
                fixture.measurements = .init(local: local, links: links)
                let result = try fixture.result().proposals[0]
                let transfer = result.prefill.tasks.first { $0.id == "prefill0forward" }!
                try require(transfer.costComponents["seal"] == 1 && transfer.costComponents["open"] == 1 &&
                            transfer.costComponents["recordCryptoFixed"] == 4 &&
                            transfer.endNanoseconds - transfer.startNanoseconds == 9, "all crypto components included")
            }),
            ("cycles_and_bare_cross_rank_edges_refuse", {
                var fixture = PlacementFixture.pipeline(); let candidate = fixture.request.candidates[0]
                var tasks = candidate.prefill
                tasks[0] = try replacing(tasks[0], "dependencies", ["prefill0ack"])
                fixture.candidates([try replacing(candidate, "prefill", object(tasks))])
                try refused(fixture, containing: "cyclic")
                tasks = candidate.prefill; tasks[2] = try replacing(tasks[2], "dependencies", ["prefill0a"])
                fixture.candidates([try replacing(candidate, "prefill", object(tasks))])
                try refused(fixture, containing: "unmeasured cross-node edge")
            }),
            ("missing_duplicate_operator_and_future_dependency_refuse", {
                var fixture = PlacementFixture.pipeline(); let candidate = fixture.request.candidates[0]
                var tasks = candidate.prefill; tasks.remove(at: 0)
                fixture.candidates([try replacing(candidate, "prefill", object(tasks))])
                try refused(fixture, containing: "task dependencies")
                tasks = candidate.prefill
                tasks.append(.init(id: "duplicate", step: 0, dependencies: [], work: tasks[0].work))
                fixture.candidates([try replacing(candidate, "prefill", object(tasks))])
                try refused(fixture, containing: "duplicate")
                tasks = candidate.prefill; tasks[0] = try replacing(tasks[0], "dependencies", ["prefill1a"])
                fixture.candidates([try replacing(candidate, "prefill", object(tasks))])
                try refused(fixture, containing: "future-step")
            }),
            ("invalid_cut_and_checked_memory_overflow", {
                var fixture = PlacementFixture.pipeline(); let candidate = fixture.request.candidates[0]
                fixture.candidates([try replacing(candidate, "prefillLayout", object(PlacementLayout.pipeline(cut: 0)))])
                try refused(fixture, containing: "pipeline cut")
                let memory = try replacing(candidate.prefillMemory[0], "workspacePeakBytes", UInt64.max)
                fixture.candidates([try replacing(candidate, "prefillMemory", object([memory, candidate.prefillMemory[1]]))])
                try refused(fixture, containing: "overflow")
                try mustThrow { _ = try PlacementMath.bytesTime(UInt64.max, rate: 1) }
            }),
            ("deterministic_tie_and_calibration_references", {
                var fixture = PlacementFixture.pipeline(); let candidate = fixture.request.candidates[0]
                let earlier = try replacing(candidate, "id", "aaa")
                fixture.candidates([candidate, earlier])
                let result = try fixture.result()
                try require(result.preferredCandidateID == "aaa" && result.predictionOnly &&
                            result.proposals[0].adapterRecipeSHA256 == PlacementFixture.digest &&
                            result.proposals[0].prefill.tasks.allSatisfy { $0.evidenceSHA256 == PlacementFixture.digest },
                            "deterministic choice retains references")
            }),
            ("public_json_version_and_size_boundary", {
                let fixture = PlacementFixture.pipeline()
                let envelope = PlacementEnvelope(schema: "measured_two_node_placement_v1", request: fixture.request,
                    measurements: fixture.measurements, objective: .totalRequest)
                let data = try JSONEncoder().encode(envelope)
                let result = try JSONDecoder().decode(PlacementReport.self, from: MeasuredPlacementAPI.predict(data))
                try require(result.preferredCandidateID == "pipeline" && result.predictionOnly, "JSON facade")
                let wrong = try replacing(envelope, "schema", "v2")
                try mustThrow { _ = try MeasuredPlacementAPI.predict(JSONEncoder().encode(wrong)) }
                try mustThrow { _ = try MeasuredPlacementAPI.predict(Data(repeating: 0, count: 16_777_217)) }
            })]
        for (name, body) in checks { try body(); print("PASS " + name) }
        print("PASS \(checks.count) placement groups (synthetic fixtures only)")
    }
}
