// Copyright © 2026 Eigen Labs.
//
// LIVE C1/C5 measurement on the real LFM2.5-24B-A2B artifact through the
// production bundle on THIS Mac: MLX peak memory versus the scanner's LOAD
// estimate and the activation reserve, for single requests at several
// context sizes and for concurrent requests, plus the provider's own
// admission behaviour when the requested KV exceeds what it can admit, and the
// bridge's context cap (recorded). Measurement only: it asserts that
// every admitted request completes and that nothing leaks; the qualified
// envelope is derived from the recorded numbers by the operator, never here.
//
// DARKBLOOM_LFM25_QUAL_CONTEXTS (comma list of prompt tokens, default
// 4096,16384,32768,65536,131000) and DARKBLOOM_LFM25_QUAL_CONCURRENCY
// ("<B>x<tokens>,...", default 4x8192,8x8192,8x16384) select the cells.
// A cell is skipped (and recorded as not measured) if the previous peak left
// less than 3 GiB of real system memory, so the run never drives the Mac
// into swap.

import Foundation
import MLX
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("LFM2.5-24B-A2B memory envelope measurement (live)", .serialized,
       .enabled(if: LFM25Qual.selected("memory")))
struct LFM25MemoryQualificationLiveTests {
    private static let gib = 1_073_741_824

    private static var contexts: [Int] {
        (LFM25Qual.environment["DARKBLOOM_LFM25_QUAL_CONTEXTS"] ?? "4096,16384,32768,65536,131000")
            .split(separator: ",").compactMap { Int($0) }
    }

    private static var concurrency: [(Int, Int)] {
        (LFM25Qual.environment["DARKBLOOM_LFM25_QUAL_CONCURRENCY"] ?? "4x8192,8x8192,8x16384")
            .split(separator: ",").compactMap { cell in
                let parts = cell.split(separator: "x").compactMap { Int($0) }
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
    }

    /// Prompt of exactly `count` tokens: ChatML frame + synthetic records,
    /// trimmed inside the user turn so the generation prompt stays intact.
    private static func prompt(_ model: LFM25Loaded, tokens count: Int, salt: Int) -> [Int] {
        let head = model.encode("<|startoftext|><|im_start|>user\n")
        let tail = model.encode(" Summarize briefly.<|im_end|>\n<|im_start|>assistant\n<think>")
        let need = max(0, count - head.count - tail.count)
        var body: [Int] = []
        var next = 0
        while body.count < need {
            body += model.encode(LFM25Qual.records(next ..< next + 200, salt: salt) + " ")
            next += 200
        }
        return head + body.prefix(need) + tail
    }

    private static func availableGiB() -> Double {
        Double(SystemMemory.availableBytes() ?? 0) / Double(gib)
    }

    /// Process physical footprint (includes MLX's retained buffer cache,
    /// which `peakMemory` does not).
    private static func footprintBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : -1
    }

    @Test("peak memory vs LOAD estimate and reserve; admission when requested KV exceeds what fits")
    func memoryEnvelope() async throws {
        let model = try await LFM25Loaded.load()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lfm25-qual-mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let slot = try await LFM25Slot.make(model, maxConcurrent: 8, cacheRoot: root)
        let idle = try await slot.settled()
        MLX.Memory.clearCache()
        let resident = MLX.Memory.activeMemory
        var evidence: [String: Any] = [
            "physicalBytes": ProcessInfo.processInfo.physicalMemory,
            "hardCapBytes": UnifiedMemoryCap.hardCapBytes(),
            "loadEstimateGiB": model.info.estimatedMemoryGb,
            "loadHeadroomGiB": ModelLoadAdmission.defaultLoadHeadroomGb,
            "weightsBytes": model.sizing.weightsBytes, "kvBytesPerToken": model.sizing.fp16KVBytesPerToken,
            "maxContextLength": model.sizing.maxContextLength,
            "activationReserveBytes": slot.activationReserveBytes, "configReserveBytes": slot.configReserveBytes,
            "slotKVGrantBytes": slot.kvBytesCapacity, "fixedRequestBytes": await slot.bridge.fixedRequestBytes,
            "residentActiveBytes": resident, "idle": idle.evidence,
            "systemAvailableGiBAtStart": Self.availableGiB(),
        ]
        var stop = false

        // Single requests across context sizes (cold, cache disabled so the
        // number is the serving step itself, not checkpoint serialization).
        var singles: [[String: Any]] = []
        for (index, context) in Self.contexts.enumerated() {
            if stop || context > model.sizing.maxContextLength {
                singles.append(["context": context, "measured": false,
                                "reason": stop ? "low system memory after previous cell" : "above max context"])
                continue
            }
            let tokens = Self.prompt(model, tokens: context, salt: 900 + index)
            MLX.Memory.clearCache()
            MLX.Memory.peakMemory = 0
            let run = await LFM25Run.run(slot, tokens: tokens, maxTokens: 16, id: "mem-single-\(context)",
                                         cacheEnabled: false)
            let peak = MLX.Memory.peakMemory
            let settled = try await slot.settled(idle: idle)
            #expect(run.error == nil, "context \(context): \(run.error ?? "")")
            #expect(settled.kvBytesInUse == idle.kvBytesInUse)
            let kv = context * model.sizing.fp16KVBytesPerToken
            let cell: [String: Any] = [
                "context": context, "promptTokens": tokens.count, "measured": true, "run": run.evidence,
                "peakBytes": peak, "peakOverResidentBytes": peak - resident,
                "peakOverResidentPlusKVBytes": peak - resident - kv, "kvLogicalBytes": kv,
                "systemAvailableGiBAfter": Self.availableGiB(),
                "mlxCacheBytesAfter": MLX.Memory.cacheMemory, "footprintBytesAfter": Self.footprintBytes(),
            ]
            singles.append(cell)
            print("LFM25-QUAL memory single ctx=\(context) seconds=\(String(format: "%.1f", run.seconds)) "
                + "peakGiB=\(String(format: "%.2f", LFM25Qual.gib(peak))) "
                + "overResidentGiB=\(String(format: "%.2f", LFM25Qual.gib(peak - resident))) "
                + "overResidentPlusKVGiB=\(String(format: "%.2f", LFM25Qual.gib(peak - resident - kv)))")
            if Self.availableGiB() < 3 { stop = true }
        }
        evidence["singles"] = singles

        // Concurrent cells.
        var cells: [[String: Any]] = []
        for (width, context) in Self.concurrency {
            if stop { cells.append(["width": width, "context": context, "measured": false]); continue }
            let prompts = (0 ..< width).map { Self.prompt(model, tokens: context, salt: 2_000 + width * 10 + $0) }
            MLX.Memory.clearCache()
            MLX.Memory.peakMemory = 0
            let before = await slot.capacity()
            let runs = await withTaskGroup(of: LFM25Run.self) { group in
                for (row, tokens) in prompts.enumerated() {
                    group.addTask {
                        await LFM25Run.run(slot, tokens: tokens, maxTokens: 192,
                                           id: "mem-b\(width)-\(context)-\(row)", cacheEnabled: false)
                    }
                }
                var out: [LFM25Run] = []
                for await run in group { out.append(run) }
                return out
            }
            let peak = MLX.Memory.peakMemory
            let after = try await slot.settled(idle: idle)
            #expect(runs.allSatisfy { $0.error == nil })
            #expect(after.kvBytesInUse == idle.kvBytesInUse)
            let kv = width * context * model.sizing.fp16KVBytesPerToken
            let steps = after.stepsExecuted - before.stepsExecuted
            let rows = Int(after.decodeRowsTotal - before.decodeRowsTotal)
            cells.append([
                "width": width, "context": context, "measured": true,
                "errors": runs.filter { $0.error != nil }.count,
                "batchRowsMax": runs.compactMap { $0.engine?.batchRowsMax }.max() ?? -1,
                "meanDecodeRowsPerStep": steps > 0 ? Double(rows) / Double(steps) : 0,
                "peakBytes": peak, "peakOverResidentBytes": peak - resident,
                "peakOverResidentPlusKVBytes": peak - resident - kv, "kvLogicalBytes": kv,
                "seconds": runs.map(\.seconds).max() ?? 0, "systemAvailableGiBAfter": Self.availableGiB(),
                "mlxCacheBytesAfter": MLX.Memory.cacheMemory, "footprintBytesAfter": Self.footprintBytes(),
            ])
            print("LFM25-QUAL memory B=\(width) ctx=\(context) peakGiB=\(String(format: "%.2f", LFM25Qual.gib(peak))) "
                + "overResidentPlusKVGiB=\(String(format: "%.2f", LFM25Qual.gib(peak - resident - kv)))")
            if Self.availableGiB() < 3 { stop = true }
        }
        evidence["concurrent"] = cells

        // Admission at the slot grant: eight requests that each reserve a full
        // 131,072-token context (prompt 1,024 + max_tokens 130,048) ask for
        // ~21.5 GB of KV against the grant. Record what the provider admits,
        // queues or refuses, then cancel everything.
        let probes = (0 ..< 8).map { "mem-probe-\($0)" }
        let probeTasks = probes.enumerated().map { index, id in
            let tokens = Self.prompt(model, tokens: 1_024, salt: 5_000 + index)
            return Task { await LFM25Run.run(slot, tokens: tokens, maxTokens: 131_072 - 1_024,
                                             id: id, cacheEnabled: false) }
        }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let probeSnapshot = await slot.capacity()
        for id in probes { await slot.bridge.cancel(requestId: id) }
        var probeRuns: [LFM25Run] = []
        for task in probeTasks { probeRuns.append(await task.value) }
        let afterProbe = try await slot.settled(idle: idle)
        #expect(afterProbe.kvBytesInUse == idle.kvBytesInUse)
        #expect(afterProbe.kvBytesReserved == idle.kvBytesReserved)
        evidence["admissionProbe"] = [
            "requestedKVBytesPerRequest": 131_072 * model.sizing.fp16KVBytesPerToken,
            "duringProbe": probeSnapshot.evidence, "runs": probeRuns.map(\.evidence),
            "afterCancel": afterProbe.evidence,
        ]
        print("LFM25-QUAL memory admission probe active=\(probeSnapshot.activeRequests) "
            + "waiting=\(probeSnapshot.waitingRequests) reserved=\(probeSnapshot.kvBytesReserved) "
            + "capacity=\(probeSnapshot.kvBytesCapacity) errors=\(probeRuns.filter { $0.error != nil }.count)")

        // Context limit: for LFM the bridge carries no advertised context cap
        // (EngineV2SlotFactory sets advertisedContextTokens only for Qwen4 or
        // a qualified performance/deadline profile), so the provider does not
        // itself refuse prompt + max_tokens above max_position_embeddings; the
        // coordinator catalog gate does. Recorded, not asserted (gap).
        evidence["bridgeAdvertisedContextTokens"] = slot.bridge.advertisedContextTokens ?? -1
        evidence["finalPeakBytes"] = MLX.Memory.peakMemory
        evidence["finalFootprintBytes"] = Self.footprintBytes()
        LFM25Qual.writeEvidence("memory", evidence)
        await slot.bridge.shutdown()
        MLX.Memory.clearCache()
    }
}
