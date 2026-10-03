import Foundation
import ProviderCoreFoundation
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

/// Verification-only local fixture. Copy into the provider live-test target
/// only after the frozen required pipeline, run explicitly, then remove it.
@Suite("Qwen3.5 protected mixed checkpoint measurement", .serialized)
struct Qwen35MixedCheckpointBenchmark {
  @Test(
    .timeLimit(.minutes(15)),
    .enabled(
      if:
        ProcessInfo.processInfo.environment["DARKBLOOM_MIXED_CHECKPOINT_BENCHMARK"] == "1"))
  func realMixedCohort() async throws {
    let fixture = try await Qwen35CheckpointRetentionFixture()
    do {
      var cells: [[String: Any]] = []
      var reference: [Int: [[Int]]] = [:]
      var parity: [Int: Bool] = [:]
      // Untimed shape priming, then counterbalanced measured pairs.
      for (pair, order) in [
        (-1, [false, true]), (0, [false, true]),
        (1, [true, false]), (2, [false, true]),
      ] {
        for demanded in order {
          let result = try await run(fixture, pair: pair, demanded: demanded)
          if let tokens = reference[pair] {
            parity[pair] = result.tokens == tokens
            #expect(result.tokens == tokens, "actual token IDs must match the paired control")
          } else {
            reference[pair] = result.tokens
          }
          if pair >= 0 { cells.append(result.metrics) }
        }
      }
      let report: [String: Any] = [
        "sdk_pin": "58d538c8a9668f72a2702d5bb348e0e53a8cdf61",
        "model": fixture.modelID, "model_hash": fixture.modelHash,
        "runtime_mtp": false, "artifact_declares_and_loads_mtp_head": fixture.mtpActive,
        "pairs": 3, "shape_priming_cells_excluded": 2,
        "paired_generated_token_ids_equal": (0..<3).map {
          ["pair": $0, "equal": parity[$0] == true] as [String: Any]
        },
        "profile":
          "production factory benchmark width3; serialized partials1; plain512/base2048/solo4096; SSD floor1024 unchanged",
        "explicit_fixture_configuration": [
          "construction_purpose": "benchmark", "max_concurrent_requests": 3,
          "kv_budget_bytes": 16 << 30, "solo_prefill_stripe_tokens": 4096,
          "runtime_mtp_enabled": false,
        ] as [String: Any],
        "control":
          "repeat demand zero; same factory, actual model, scope and prompts; zero imported tokens",
        "prompt_shape":
          "pre-tokenized synthetic fixture, clipped to exact 1/2049/2800 token lengths",
        "output_shape":
          "forced length3/1/128, no early stop tokens; not a natural-answer quality benchmark",
        "timing":
          "submit to first raw token/first visible delta and finish; setup and asynchronous write completion separate. Legacy durable_drain_seconds field means write completion with strictFsync=false, not fsync durability.",
        "aggregate_input_rate":
          "actual input tokens divided by cohort elapsed; prefill service proxy, not kernel TPS",
        "measurement_scope":
          "Mixed-cohort capture creation cost; packing overhead is not isolated unless the measured control actually packs the same donor range.",
        "cells": cells,
      ]
      let destination = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment[
          "DARKBLOOM_MIXED_CHECKPOINT_BENCHMARK_OUTPUT"]
          ?? "/tmp/darkbloom-cache-performance-validation/qwen-mixed-cohort.json")
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: destination, options: .atomic)
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }

  @Test(
    .timeLimit(.minutes(10)),
    .enabled(
      if:
        ProcessInfo.processInfo.environment["DARKBLOOM_MIXED_WARM_BENCHMARK"] == "1"))
  func realMixedWarmFork() async throws {
    let fixture = try await Qwen35CheckpointRetentionFixture()
    do {
      let seed = try await run(fixture, pair: -2, demanded: true)
      let prompt = Array(fixture.prompts.donor.prefix(2300))
      var cells: [[String: Any]] = []
      var outputs: [[Int]] = []
      for warm in [false, true] {
        let store = try fixture.makeStore()
        let build = try EngineV2Factory.makeProductionBuild(
          model: fixture.model, modelID: fixture.modelID, tokenizer: fixture.tokenizer.inner,
          kvBytesCapacity: 16 << 30, maxConcurrentRequests: 3, constructionPurpose: .benchmark,
          completePrefixCache: store, mtpDrafter: nil, mtpConfig: .init(), kvBackend: .paged,
          environment: ["DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE": "4096"])
        let engine = try #require(build.engine as? EngineV2)
        do {
          try #require(engine.mtpMetricsSnapshot() == nil)
          let id = CBv2RequestID(warm ? 82002 : 82001)
          let request = CBv2Request(
            id: id, promptTokens: prompt, sampling: .init(temperature: 0),
            maxTokens: 128, cacheSalt: "tenant-mixed--2-neighbor", prefixCacheEnabled: warm,
            prefixCacheReceiptID: id)
          let start = ContinuousClock.now
          var stageSeconds = 0.0
          if warm {
            let result = await store.stage(
              requestID: id, request: request,
              reserveReadScratch: { try engine.reserveCompleteCheckpointReadScratch() }
            ) {
              try engine.planCompleteCheckpointImport(manifest: $0, request: request)
            }
            stageSeconds = seconds(ContinuousClock.now - start)
            try #require(result.staged, "actual authenticated SSD stage must succeed")
          }
          let output = await collect(try engine.submit(request), start: start)
          try #require(output.completion == 128 && output.hit == (warm ? 2048 : 0))
          outputs.append(output.tokens)
          cells.append([
            "warm": warm, "prompt_tokens": prompt.count, "completion_tokens": output.completion,
            "hit_tokens": output.hit, "ttft_seconds": output.ttft,
            "first_visible_seconds": output.firstVisible.map { $0 as Any } ?? NSNull(),
            "elapsed_seconds": output.elapsed, "stage_seconds": stageSeconds,
            "bytes_read": store.stats().bytesRead,
            "decode_tail_tokens_per_second": output.tailTPS.map { $0 as Any } ?? NSNull(),
          ])
          await engine.shutdown()
          await store.closeAndWait()
        } catch {
          await engine.shutdown()
          await store.closeAndWait()
          throw error
        }
      }
      try #require(
        outputs[0] == outputs[1], "same-MTP-off restored fork must preserve exact token IDs")
      let report: [String: Any] = [
        "sdk_pin": "58d538c8a9668f72a2702d5bb348e0e53a8cdf61", "model": fixture.modelID,
        "model_hash": fixture.modelHash, "runtime_mtp": false, "pairs": 1,
        "paired_generated_token_ids_equal": true, "seed_cohort": seed.metrics, "cells": cells,
        "measurement":
          "Separate single cold/warm MTP-off fork; stage is included in TTFT. Same factory width3, one active fork, 2300 input/128 forced output. No blocker hooks or restore overrides. Not pooled with earlier timing aggregates.",
      ]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(
          to: URL(
            fileURLWithPath: "/tmp/darkbloom-cache-performance-validation/qwen-mixed-warm.json"),
          options: .atomic)
      await fixture.close()
    } catch {
      await fixture.close()
      throw error
    }
  }

  private struct Output: Sendable {
    let tokens: [Int]
    let ttft: Double
    let firstVisible: Double?
    let elapsed: Double
    let tailTPS: Double?
    let hit: Int
    let completion: Int
  }

  private struct Cell {
    let tokens: [[Int]]
    let metrics: [String: Any]
  }

  private func run(_ fixture: Qwen35CheckpointRetentionFixture, pair: Int, demanded: Bool)
    async throws -> Cell
  {
    let setupStart = ContinuousClock.now
    let store = try fixture.makeStore()
    let build = try EngineV2Factory.makeProductionBuild(
      model: fixture.model, modelID: fixture.modelID, tokenizer: fixture.tokenizer.inner,
      kvBytesCapacity: 16 << 30, maxConcurrentRequests: 3, constructionPurpose: .benchmark,
      completePrefixCache: store, mtpDrafter: nil, mtpConfig: .init(),
      kvBackend: .paged, environment: ["DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE": "4096"])
    let engine = try #require(build.engine as? EngineV2)
    do {
      let settings = engine.loopForTesting.scheduler.config
      try #require(
        settings.maxConcurrentRequests == 3 && settings.maxConcurrentPartialPrefills == 1)
      try #require(settings.prefillChunkSize == 512 && settings.maxBatchedTokensPerStep == 2048)
      try #require(
        settings.soloPrefillStripeTokens == 4096
          && settings.demandedShortCheckpointMinimumTokens == 1024)
      try #require(engine.mtpMetricsSnapshot() == nil && engine.packedPrefillActivity().isSupported)
      let observed = RecurrentGeometryObservationsForBenchmark()
      let scopes = [
        "tenant-mixed-\(pair)-blocker", "tenant-mixed-\(pair)-neighbor",
        "tenant-mixed-\(pair)-target",
      ]
      let prompts = [
        Array(fixture.prompts.donor.prefix(1)),
        Array(fixture.prompts.donor.prefix(2049)), Array(fixture.prompts.donor.prefix(2800)),
      ]
      let lengths = [3, 1, 128]
      let ids = [CBv2RequestID(81001), CBv2RequestID(81002), CBv2RequestID(81003)]
      let setupSeconds = seconds(ContinuousClock.now - setupStart)
      let start = ContinuousClock.now
      let streams = try engine.loopForTesting.onEngineQueueSync {
        engine.loopForTesting.recurrentGeometryObserverForTesting = {
          [weak engine] id, range, cap, packed, phase, outcome in
          guard phase == "record" else { return }
          observed.append(
            id: id.raw, step: engine?.loopForTesting.stepCount ?? -1, range: range, cap: cap ?? 0,
            packed: packed, outcome: outcome)
        }
        return try ids.indices.map { index in
          let hint = demanded && index > 0 ? (index == 1 ? 2048 : 2311) : 0
          store.registerDonationDemand(.init(repeatedPrefixTokens: hint), requestID: ids[index])
          return try engine.submit(
            CBv2Request(
              id: ids[index], promptTokens: prompts[index], sampling: .init(temperature: 0),
              maxTokens: lengths[index], cacheSalt: scopes[index],
              prefixCacheReceiptID: ids[index], prefixCheckpointTargetTokens: hint))
        }
      }
      let collectors = streams.map { stream in Task { await collect(stream, start: start) } }
      var outputs: [Output] = []
      for collector in collectors { outputs.append(await collector.value) }
      let elapsed = outputs.map(\.elapsed).max() ?? 0
      try #require(outputs.map(\.completion) == lengths && outputs.allSatisfy { $0.hit == 0 })
      let drainStart = ContinuousClock.now
      await store.waitForWritesForTesting()
      let drainSeconds = seconds(ContinuousClock.now - drainStart)
      let rows = observed.snapshot
      let introduced = rows.first {
        $0.id == ids[1].raw && $0.lower == 1536 && $0.upper == 2048 && $0.cap == 4096
      }
      let sameStepOpportunity =
        introduced.map { boundary in
          rows.contains {
            $0.id == ids[2].raw && $0.step == boundary.step && $0.upper - $0.lower == 512
              && $0.upper < prompts[2].count
          }
        } ?? false
      let donorActuallyPacked = rows.contains { $0.id == ids[1].raw && $0.packed }
      if demanded {
        try #require(
          sameStepOpportunity,
          "same-sized nonfinal neighbor must execute in the boundary's actual step")
        try #require(
          rows.contains {
            $0.id == ids[1].raw && $0.lower == 1536 && $0.upper == 2048 && $0.cap == 4096
              && !$0.packed
          }, "the actual introduced range must execute as a singleton")
        let positions = try checkpointRecords(fixture, scope: scopes[1], tokens: prompts[1])
          .positions
        try #require(
          positions.contains(2048),
          "the protected target must become an authenticated encrypted file")
      }
      let saved = try ids.indices.map {
        try checkpointRecords(fixture, scope: scopes[$0], tokens: prompts[$0])
      }
      let totalInput = prompts.reduce(0) { $0 + $1.count }
      let totalOutput = outputs.reduce(0) { $0 + $1.completion }
      let metrics: [String: Any] = [
        "pair": pair, "demanded": demanded,
        "setup_seconds": setupSeconds, "cohort_seconds": elapsed,
        "durable_drain_seconds": drainSeconds,
        "input_tokens": totalInput, "output_tokens": totalOutput,
        "aggregate_input_tokens_per_second": Double(totalInput) / elapsed,
        "aggregate_output_tokens_per_second": Double(totalOutput) / elapsed,
        "aggregate_all_tokens_per_second": Double(totalInput + totalOutput) / elapsed,
        "files_written": store.stats().filesWritten, "bytes_written": store.stats().bytesWritten,
        "packed_executed": engine.packedPrefillActivity().didExecute,
        "donor_actually_packed": donorActuallyPacked,
        "introduced_same_step_same_size_nonfinal_opportunity": sameStepOpportunity,
        "rows": outputs.enumerated().map { index, output in
          [
            "row": index, "prompt_tokens": prompts[index].count,
            "completion_tokens": output.completion,
            "hit_tokens": output.hit, "ttft_seconds": output.ttft,
            "authenticated_file_positions": saved[index].positions,
            "file_tensor_bytes": saved[index].bytes,
            "first_visible_seconds": output.firstVisible.map { $0 as Any } ?? NSNull(),
            "elapsed_seconds": output.elapsed,
            "decode_tail_tokens_per_second": output.tailTPS.map { $0 as Any } ?? NSNull(),
          ] as [String: Any]
        },
        "geometry": rows.map {
          [
            "row": Int($0.id - ids[0].raw), "step": $0.step, "lower": $0.lower,
            "upper": $0.upper, "cap": $0.cap, "packed": $0.packed, "outcome": $0.outcome,
          ] as [String: Any]
        },
      ]
      print(
        "[qwen35-mixed] pair=\(pair) demand=\(demanded) elapsed=\(elapsed) TTFT=\(outputs.map(\.ttft)) output=\(totalOutput) packed=\(engine.packedPrefillActivity().didExecute)"
      )
      await engine.shutdown()
      await store.closeAndWait()
      return Cell(tokens: outputs.map(\.tokens), metrics: metrics)
    } catch {
      await engine.shutdown()
      await store.closeAndWait()
      throw error
    }
  }

  /// Cold controls legitimately have no files; every existing file still authenticates.
  private func checkpointRecords(
    _ fixture: Qwen35CheckpointRetentionFixture, scope: String,
    tokens: [Int]
  ) throws -> (positions: [Int], bytes: [Int]) {
    let enumerator = try #require(
      FileManager.default.enumerator(at: fixture.root, includingPropertiesForKeys: nil))
    let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "dbk3" }
    let manifests = try files.map { file in
      var bytes: Data?
      try SSDBlockStore.readStreaming(
        from: file, kekKey: fixture.key,
        maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
        maximumPlaintextBytes: SSDPrefixCachePolicy.maxStageBytes(environment: [:]),
        requireEOF: true, validateMetadata: { _ in },
        consumeChunk: { index, data in if index == 0 { bytes = data } })
      let manifest = try SSDHybridCheckpointEnvelope.decodeManifest(try #require(bytes))
      try #require(manifest.identity == fixture.identity)
      try #require(manifest.backendLayout == CBv2CompleteCheckpointManifest.pagedLayout)
      try #require(manifest.position % PrefixCachePolicy.blockSize == 0 && manifest.chunkSize > 0)
      return manifest
    }.filter { $0.cacheSalt == scope && tokens.starts(with: $0.prefixTokens) }
      .sorted { $0.position < $1.position }
    return (manifests.map(\.position), manifests.map { $0.tensors.reduce(0) { $0 + $1.byteCount } })
  }

  private func collect(_ stream: AsyncStream<CBv2Event>, start: ContinuousClock.Instant) async
    -> Output
  {
    var tokens: [Int] = []
    var first: ContinuousClock.Instant?
    var visible: ContinuousClock.Instant?
    var last: ContinuousClock.Instant?
    var hit = 0
    var completion = 0
    var finished = ContinuousClock.now
    for await event in stream {
      switch event {
      case .delta(let text, let ids, _):
        if !ids.isEmpty {
          if first == nil { first = .now }
          last = .now
          tokens += ids
        }
        if !text.isEmpty && visible == nil { visible = .now }
      case .finished(let reason, let usage):
        #expect(reason == .length)
        hit = usage.prefixCacheHitTokens
        completion = usage.completionTokens
        finished = .now
      }
    }
    let tail = first.flatMap { initial in last.map { seconds($0 - initial) } } ?? 0
    return Output(
      tokens: tokens, ttft: seconds((first ?? finished) - start),
      firstVisible: visible.map { seconds($0 - start) }, elapsed: seconds(finished - start),
      tailTPS: tokens.count > 1 && tail > 0 ? Double(tokens.count - 1) / tail : nil,
      hit: hit, completion: completion)
  }

  private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }
}

private final class RecurrentGeometryObservationsForBenchmark: @unchecked Sendable {
  struct Row {
    let id: UInt64
    let step: Int
    let lower: Int
    let upper: Int
    let cap: Int
    let packed: Bool
    let outcome: String
  }
  private let lock = NSLock()
  private var rows: [Row] = []
  func append(id: UInt64, step: Int, range: Range<Int>, cap: Int, packed: Bool, outcome: String) {
    lock.lock()
    defer { lock.unlock() }
    rows.append(
      .init(
        id: id, step: step, lower: range.lowerBound, upper: range.upperBound,
        cap: cap, packed: packed, outcome: outcome))
  }
  var snapshot: [Row] {
    lock.lock()
    defer { lock.unlock() }
    return rows
  }
}
