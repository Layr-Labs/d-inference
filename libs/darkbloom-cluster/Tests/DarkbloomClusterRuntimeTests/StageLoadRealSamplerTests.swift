import Darwin
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// The sampler and the three gates against this Mac's real counters. Nothing is
// loaded: these read the kernel's statistics, a few sysctls and source files.
// They exist to notice a kernel whose counters stop meaning what the policy
// assumes, and a gate that stops asking the policy.

@Suite("Host memory sampler and gates on this Mac (reads counters, loads nothing)", .serialized)
struct StageLoadRealSamplerTests {
    private static func sysctlInteger(_ name: String) -> Int? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<UInt32>.size {
            var value: UInt32 = 0
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
        }
        if size == MemoryLayout<UInt64>.size {
            var value: UInt64 = 0
            return sysctlbyname(name, &value, &size, nil, 0) == 0 && value <= UInt64(Int.max) ? Int(value) : nil
        }
        return nil
    }

    /// Counters the pageout scan advances. If their sum moved, the scan ran.
    private static func pageoutScanActivity() -> Int? {
        let names = ["vm.pageout_inactive_clean", "vm.pageout_inactive_used", "vm.pageout_speculative_clean",
                     "vm.pageout_inactive_dirty_internal", "vm.pageout_freed_external"]
        let values = names.compactMap(sysctlInteger)
        return values.count == names.count ? values.reduce(0, +) : nil
    }

    @Test func aRealSampleIsValidAndJudged() throws {
        let os = try QwenDenseStageLoadResources.observeOS()
        #expect(os.startedNanoseconds <= os.completedNanoseconds)
        #expect(os.completedNanoseconds - os.startedNanoseconds < 100_000_000, "one sample took more than 0.1 s")
        // This macOS reports both the inactive file-backed count and its own minimum.
        #expect(os.inactiveFileBackedPages != nil && os.inactiveAnonymousPages != nil)
        #expect(os.kernelFileCacheMinimumPages != nil)
        // The compression counter the guard reads by sysctl is the one the
        // statistics report: they have stayed within 0.01 % of each other
        // over days of uptime on both Macs. (This test process is Apple's
        // runner, which the kernel does not serve cached statistics.)
        let live = try #require(os.liveCompressionPages)
        #expect(abs(live - os.compressionPages) <= max(4_096, os.compressionPages / 50),
                "sysctl \(live) pages, statistics \(os.compressionPages)")
        #expect(QwenDenseStageLoadResources.kernelCounter("vm.pageout_inactive_dirty_internal") ?? 0 >= live)
        #expect(QwenDenseStageLoadResources.kernelCounter("vm.no_such_counter_for_this_test") == nil)
        #expect(os.fileBackedPages > 0 && os.anonymousPages > 0 && os.activePages > 0)
        let decision = try QwenDenseStageLoadPolicy.decide(os, requiredBytes: 0, purpose: "Sampler test",
            now: DispatchTime.now().uptimeNanoseconds, since: .init(os))
        #expect(decision.policy == QwenDenseStageLoadPolicy.identifier)
        #expect(decision.compressedSinceFirstSampleBytes == 0 && decision.swappedOutSinceFirstSampleBytes == 0)
        #expect(decision.countableFileCacheBytes <= decision.fileCacheAboveReserveBytes)
        #expect(decision.countedReclaimableBytes <= QwenDenseStageLoadPolicy.maximumCountedReclaimableBytes)
        // Lifetime counters only go up: a second sample is judged against the first.
        let again = try QwenDenseStageLoadResources.observeOS()
        #expect(again.compressionPages >= os.compressionPages && again.swapoutPages >= os.swapoutPages)
        _ = try QwenDenseStageLoadPolicy.decide(again, requiredBytes: 0, purpose: "Sampler test",
            now: DispatchTime.now().uptimeNanoseconds, since: .init(os))
    }

    @Test func fileBackedPlusAnonymousIsTheActiveInactiveAndSpeculativeQueues() throws {
        // The policy treats `external_page_count` as the file cache and
        // `internal_page_count` as anonymous memory. Together they are the
        // pageable queues; the kernel fills the counters one after another, so
        // a few pages may be in flight.
        var worst = 0
        for _ in 0..<20 {
            let os = try QwenDenseStageLoadResources.observeOS()
            let queues = os.activePages + os.inactivePages + os.speculativePages
            worst = max(worst, abs(os.fileBackedPages + os.anonymousPages - queues))
            let inactive = (os.inactiveFileBackedPages ?? 0) + (os.inactiveAnonymousPages ?? 0)
            worst = max(worst, abs(inactive - os.inactivePages))
            usleep(50_000)
        }
        print("stage-load sampler: largest disagreement between counter sums over 20 samples: \(worst) pages")
        #expect(worst <= QwenDenseStageLoadPolicy.counterSlackPages)
    }

    @Test func theKernelFileCacheMinimumIsTheFormulaThePolicyUses() throws {
        // XNU: (active + inactive + free + speculative) * 10 / 27, recomputed
        // when the pageout scan runs. Between scans the published figure is
        // old: after a request that wired a model's weights it was seen 15 %
        // off on a 128 GiB Mac. So: every sample must be within 20 %, and a
        // sample taken while the scan is running must be within 3 % (recorded
        // samples taken then were within 0.5 %). A different divisor in a
        // later kernel fails one or both.
        func ratio() throws -> Double {
            let os = try QwenDenseStageLoadResources.observeOS()
            let minimum = try #require(os.kernelFileCacheMinimumPages)
            let pageable = os.activePages + os.inactivePages + os.kernelFreePages
            return Double(minimum) * 27 / (Double(pageable) * 10)
        }
        var fresh: [Double] = [], all: [Double] = []
        var before = Self.pageoutScanActivity()
        for _ in 0..<40 {
            usleep(100_000)
            let value = try ratio()
            let after = Self.pageoutScanActivity()
            all.append(value)
            if let before, let after, after != before { fresh.append(value) }
            before = after
        }
        let loose = all.map { abs($0 - 1) }.max() ?? 1
        #expect(loose <= 0.20, "kernel minimum is \(loose * 100) % from the formula")
        if let tight = fresh.map({ abs($0 - 1) }).min() {
            print("stage-load sampler: kernel minimum within \(tight * 100) % of the formula while the scan ran "
                + "(\(fresh.count) of \(all.count) samples), \(loose * 100) % at worst")
            #expect(tight <= 0.03, "kernel minimum is \(tight * 100) % from the formula while the scan runs")
        } else {
            print("stage-load sampler: the pageout scan did not run in 4 s; kernel minimum within \(loose * 100) % "
                + "of the formula, only the 20 % bound was checked")
        }
    }

    // MARK: the three gates ask the policy

    private static func source(_ relative: String) throws -> String {
        // .../libs/darkbloom-cluster/Tests/DarkbloomClusterRuntimeTests/<this file>
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = package.appendingPathComponent("Sources/DarkbloomClusterRuntime/Models/Qwen/" + relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func everyGateTakesItsDecisionFromThePolicyAndNotFromFreePages() throws {
        // Version 2 compared `os.actualFreeBytes >= required` at each of these
        // three places. A gate that goes back to comparing free pages, or that
        // stops handing its sample to its watch, fails here.
        let comparison = try NSRegularExpression(pattern: #"actualFreeBytes\s*(>=|<=|>|<)"#)
        for (file, purpose) in [("Loading/QwenResidentLoading.swift", "Resident load"),
                                ("Resources/QwenResidentRequestResources.swift", "Resident request"),
                                ("Diagnostics/QwenGenerationDiagnosticResources.swift", "Generation diagnostics")] {
            let text = try Self.source(file)
            let range = NSRange(text.startIndex..., in: text)
            #expect(comparison.numberOfMatches(in: text, range: range) == 0, "\(file) compares free pages itself")
            #expect(text.components(separatedBy: "guard try watch.admits(os, bytes: ").count == 2,
                    "\(file) does not ask its watch exactly once")
            #expect(text.contains("QwenDenseStageLoadWatch(\"\(purpose)\")"), "\(file) has no watch of its own")
            #expect(text.contains("let os = try QwenDenseStageLoadResources.observeOS()"), "\(file) does not sample")
            #expect(!text.contains("QwenDenseStageLoadPolicy.minimumActualFreeBytes"), "\(file) names the old free-page floor")
        }
    }

    @Test func theRequestGateAdmitsOnCountedCacheOnThisMac() throws {
        // The request gate, end to end on real counters. It tells a reverted
        // gate from the current one only when this Mac has fewer free pages
        // than the 6 GiB floor and enough countable cache, which is its usual
        // state after any large read; otherwise it says so and checks only
        // that the gate runs and records its pass.
        let os = try QwenDenseStageLoadResources.observeOS()
        let probe = try QwenDenseStageLoadPolicy.decide(os, requiredBytes: 0, purpose: "Sampler test",
            now: DispatchTime.now().uptimeNanoseconds)
        let floor = QwenDenseStageLoadPolicy.minimumAdmissibleBytes
        let decisive = os.actualFreeBytes < floor - 1_073_741_824
            && probe.countedReclaimableBytes >= floor + 4 * 1_073_741_824
        let allowance = QwenResidentRequestAllowance(stateBytes: 1, fusionBytes: 0, reservedBytes: 1)
        if decisive {
            try allowance.requireLive()
            let summary = allowance.watch.summary
            #expect(summary.decisions == 1 && summary.refusals == 0 && summary.reclaimableUsedForAdmission)
            #expect(summary.first?.actualFreeBytes ?? Int.max < floor)
            #expect(QwenResidentResourceAdmissionReport.current.scopes.contains { $0.purpose == "Resident request" })
            print("stage-load sampler: request gate admitted on counted cache with "
                + "\(os.actualFreeBytes / 1_048_576) MiB free (decisive)")
        } else {
            let outcome = Result { try allowance.requireLive() }
            let summary = allowance.watch.summary
            // At most one pass: the entry check may have refused before it.
            #expect(summary.decisions + summary.unjudged <= 1)
            if case .success = outcome { #expect(summary.decisions == 1 && summary.refusals == 0) }
            print("stage-load sampler: request gate ran with \(os.actualFreeBytes / 1_048_576) MiB free and "
                + "\(probe.countedReclaimableBytes / 1_048_576) MiB counted; not a state that tells the old gate from the new")
        }
    }
}
