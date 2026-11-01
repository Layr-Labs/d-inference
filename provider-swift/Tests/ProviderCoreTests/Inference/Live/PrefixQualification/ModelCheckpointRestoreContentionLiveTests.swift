import Foundation
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// Opt-in real-model regression for complete-checkpoint SSD restore TTFT on a
/// shared engine. Each pair compares the same fork prompt restored from SSD
/// and served cold under three conditions: idle, while another tenant's long
/// prefill holds the engine, and right after another tenant's donor finishes
/// (its own checkpoint write in flight). A restore must reach the demanded
/// boundary, must never produce its first token later than cold prefill of
/// the same prompt under the same condition, and must stage as fast contended
/// as idle. Each condition has its own donor and scope, so every restore stages
/// the same boundary, and a contended run must overlap the foreign prefill.
/// Timings are otherwise observations.
@Suite("Complete-checkpoint restore under contention (live)", .serialized)
struct ModelCheckpointRestoreContentionLiveTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static let enabled = environment["DARKBLOOM_RESTORE_CONTENTION_BENCHMARK"] == "1"

    struct Sample: Codable, Sendable {
        let pair: Int
        let role: String
        let promptTokens: Int
        let stageDisposition: String
        let stageMilliseconds: Double
        let restoredTokens: Int
        let firstOutputSeconds: Double
        let terminalSeconds: Double
        /// During a foreign prefill: whether that prefill was still running
        /// when this request's stage finished.
        var foreignPrefillOverlap: Bool? = nil
    }

    struct Report: Codable {
        let modelID: String
        let weightHash: String
        /// Backend, MTP, live/checkpoint precision and build identity, so a
        /// retained report identifies its import path without the input spec.
        var runtime: ModelPrefixBenchmarkReport?
        var sharedTokens = 0
        var demandedTokens = 0
        var samples: [Sample] = []
        var failure: String?

        func save(to path: String) throws {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        }
    }

    /// Raw values are the report's role suffixes for the measured fork.
    private enum Condition: String, CaseIterable {
        case idle
        case duringForeignPrefill = "during_foreign_prefill"
        case afterForeignDonor = "after_foreign_donor"

        func role(cache: Bool) -> String { (cache ? "restore_" : "cold_") + rawValue }
    }

    /// One fixture is driven by the test task plus one overlapping foreign
    /// submission; the benchmark session actor serializes shared engine access.
    private struct FixtureBox: @unchecked Sendable { let fixture: ModelPrefixBenchmarkFixture }

    @Test("SSD restore is never slower than cold prefill, idle or contended",
          .timeLimit(.minutes(60)), .enabled(if: enabled))
    func restoreUnderContention() async throws {
        let output = try #require(Self.environment["DARKBLOOM_RESTORE_CONTENTION_OUTPUT"])
        try #require(output.hasPrefix("/") && !FileManager.default.fileExists(atPath: output),
            "the report output must be a new absolute path")
        try #require(Self.environment["DARKBLOOM_PREFIX_EXCLUSIVE_GPU"] == "1",
            "the timing gates need exclusive GPU use, as ModelPrefixBenchmarkLiveTests does")
        let specification = try ModelPrefixBenchmarkSpecification.load()
        // A lossy checkpoint can legitimately restore slower than recompute
        // (docs/reports/2026-10-11-native-inference-checkpoint-storage.md), so
        // the restore-versus-cold gate only qualifies native storage.
        try #require(specification.resolvedLiveKVQuantization == "native"
            && specification.resolvedCheckpointQuantization == "native",
            "the contention gate uses native live/storage; lossy profiles belong in ModelCheckpointStorageLiveTests")
        // MiMo loads through the native engine, whose native-bound imports keep
        // device allocation; the stage gate qualifies provider-staged imports.
        try #require(specification.modelType != "mimo_v2",
            "native-bound MiMo imports are outside the provider-staged staging contract")
        let fixture = try await ModelPrefixBenchmarkFixture(specification)
        var report = Report(modelID: specification.modelID, weightHash: specification.expectedWeightHash)
        do {
            report.runtime = await fixture.makeReport(comparison: "restore_contention")
            let cell = try #require(specification.cases.first)
            let prompts = try ModelCheckpointStoragePrompts(fixture: fixture, cell: cell)
            report.sharedTokens = prompts.sharedTokens
            report.demandedTokens = prompts.demandedTokens
            var requests = RequestIDs()
            _ = try await Self.timed(fixture, id: requests.next(), pair: -1, role: "excluded_warmup",
                tokens: prompts.fork, scope: "warmup", target: nil, cache: false)
            for pair in 0..<specification.pairs {
                for condition in Condition.allCases {
                    // A fresh scope and donor per condition: a deeper checkpoint a
                    // measured fork donates can never serve a later condition.
                    let scope = "contention-\(pair)-\(condition.rawValue)"
                    report.samples.append(try await Self.timed(fixture, id: requests.next(), pair: pair,
                        role: "donor_\(condition.rawValue)", tokens: prompts.donor, scope: scope,
                        target: prompts.demandedTokens, cache: true))
                    try await fixture.session.drainCheckpointWrites()
                    for cache in [true, false] {
                        report.samples += try await Self.measureFork(fixture, condition: condition, cache: cache,
                            pair: pair, scope: scope, prompts: prompts, requests: &requests)
                        try report.save(to: output)
                    }
                }
            }
            // Record violations in the retained report before failing the test.
            let violations = try Self.restoreContractViolations(report)
            if !violations.isEmpty {
                report.failure = violations.joined(separator: "; ")
                try report.save(to: output)
            }
            #expect(violations.isEmpty, "\(violations.joined(separator: "; "))")
        } catch {
            let failure = error
            report.failure = String(describing: failure)
            do { try await fixture.close() } catch { report.failure = "\(failure); teardown: \(error)" }
            try report.save(to: output)
            throw failure
        }
        do { try await fixture.close() } catch {
            report.failure = [report.failure, "teardown: \(error)"].compactMap { $0 }.joined(separator: "; ")
            try report.save(to: output)
            throw error
        }
    }

    /// Serves the fork once, restored or cold, under one condition and returns
    /// its sample first, followed by the foreign request that created the
    /// condition. Foreign work uses its own tenant scope, so it never shares a
    /// checkpoint with the measured prompt.
    private static func measureFork(
        _ fixture: ModelPrefixBenchmarkFixture, condition: Condition, cache: Bool, pair: Int, scope: String,
        prompts: ModelCheckpointStoragePrompts, requests: inout RequestIDs
    ) async throws -> [Sample] {
        let role = condition.role(cache: cache)
        let foreignScope = "\(scope)-foreign-\(role)"
        func fork(id: UInt64) async throws -> Sample {
            try await timed(fixture, id: id, pair: pair, role: role,
                tokens: prompts.fork, scope: scope, target: nil, cache: cache)
        }
        let samples: [Sample]
        switch condition {
        case .idle:
            samples = [try await fork(id: requests.next())]
        case .duringForeignPrefill:
            let box = FixtureBox(fixture: fixture)
            let foreignID = requests.next()
            let foreignStarted = ContinuousClock.now
            // A child task, so a failed measurement cancels and joins the
            // foreign request before the caller closes the fixture.
            async let foreign = timed(box.fixture, id: foreignID, pair: pair, role: "foreign_prefill",
                tokens: prompts.donor, scope: foreignScope, target: nil, cache: false)
            // Submit while the foreign prefill is running, not before it starts.
            try await Task.sleep(for: .seconds(2))
            let measuredStarted = ContinuousClock.now
            var measured = try await fork(id: requests.next())
            let foreignSample = try await foreign
            // The foreign first token ends its prefill; it must come after the
            // measured stage, or this run did not exercise contention.
            measured.foreignPrefillOverlap = foreignStarted + .seconds(foreignSample.firstOutputSeconds)
                > measuredStarted + .milliseconds(measured.stageMilliseconds)
            samples = [measured, foreignSample]
        case .afterForeignDonor:
            let foreign = try await timed(fixture, id: requests.next(), pair: pair, role: "foreign_donor",
                tokens: prompts.donor, scope: foreignScope, target: prompts.demandedTokens, cache: true)
            samples = [try await fork(id: requests.next()), foreign]
        }
        try await fixture.session.drainCheckpointWrites()
        return samples
    }

    /// Returns every contract violation; a missing sample throws.
    private static func restoreContractViolations(_ report: Report) throws -> [String] {
        var violations: [String] = []
        for pair in Set(report.samples.map(\.pair)).sorted() where pair >= 0 {
            let idle = try #require(report.samples.first {
                $0.pair == pair && $0.role == Condition.idle.role(cache: true)
            })
            for condition in Condition.allCases {
                let restore = try #require(report.samples.first {
                    $0.pair == pair && $0.role == condition.role(cache: true)
                })
                let cold = try #require(report.samples.first {
                    $0.pair == pair && $0.role == condition.role(cache: false)
                })
                let label = "pair \(pair) \(condition.rawValue)"
                if restore.stageDisposition != "staged" || restore.restoredTokens < report.demandedTokens {
                    violations.append("\(label): restore must reach the demanded boundary")
                }
                if restore.firstOutputSeconds > cold.firstOutputSeconds {
                    violations.append("\(label): restore TTFT \(restore.firstOutputSeconds)s exceeds cold TTFT \(cold.firstOutputSeconds)s")
                }
                // Waiting on evalLock costs a whole foreign prefill chunk (2.6-3.8 s
                // measured on M5 Max) on top of the 0.3 s idle stage.
                if restore.stageMilliseconds > idle.stageMilliseconds + 1_000 {
                    violations.append("\(label): stage \(restore.stageMilliseconds)ms vs idle \(idle.stageMilliseconds)ms")
                }
                if restore.restoredTokens != idle.restoredTokens {
                    violations.append("\(label): restored \(restore.restoredTokens) tokens vs idle \(idle.restoredTokens)")
                }
                for sample in [restore, cold] where sample.foreignPrefillOverlap == false {
                    violations.append("\(label) \(sample.role): the foreign prefill ended before the measured stage, "
                        + "so contention was not exercised (raise donorTokens)")
                }
            }
        }
        return violations
    }

    /// Engine sampling IDs must be distinct while two submissions overlap.
    private struct RequestIDs {
        private var last: UInt64 = 1_000
        mutating func next() -> UInt64 { last += 1; return last }
    }

    /// TTFT starts before staging, matching the session's caller-visible clock.
    private static func timed(_ fixture: ModelPrefixBenchmarkFixture, id: UInt64, pair: Int, role: String,
                              tokens: [Int], scope: String, target: Int?, cache: Bool) async throws -> Sample {
        var request = ModelPrefixBenchmarkFixture.benchmarkRequest(tokens: tokens, scope: scope, target: target,
            cacheEnabled: cache, outputTokens: fixture.specification.outputTokens)
        request.id = CBv2RequestID(id)
        let started = ContinuousClock.now
        let submitted = try await fixture.session.submit(request)
        var first: ContinuousClock.Instant?
        var outputCount = 0
        var finish: CBv2FinishReason?
        var finalUsage: CBv2Usage?
        for await event in submitted.events {
            switch event {
            case .delta(_, let newTokens, _):
                if first == nil, !newTokens.isEmpty { first = .now }
                outputCount += newTokens.count
            case .finished(let reason, let usage):
                finish = reason
                finalUsage = usage
            }
        }
        let terminal = ContinuousClock.now
        let usage = try await ModelPrefixBenchmarkTerminal.completeSuccessfulRequest(
            finish: finish, usage: finalUsage, outputCount: outputCount,
            expectedOutputCount: fixture.specification.outputTokens) {
                await fixture.session.complete(receiptID: submitted.receiptID)
            }
        let sample = Sample(pair: pair, role: role, promptTokens: tokens.count,
            stageDisposition: submitted.stageDisposition, stageMilliseconds: submitted.stageMilliseconds,
            restoredTokens: usage.prefixCachePrefillTokensSaved,
            firstOutputSeconds: (try #require(first) - started) / .seconds(1),
            terminalSeconds: (terminal - started) / .seconds(1))
        print("[restore-contention] \(role) pair=\(pair) stage=\(sample.stageDisposition) "
            + "stage_ms=\(Int(sample.stageMilliseconds)) restored=\(sample.restoredTokens) "
            + "ttft_s=\(String(format: "%.2f", sample.firstOutputSeconds))")
        return sample
    }
}
