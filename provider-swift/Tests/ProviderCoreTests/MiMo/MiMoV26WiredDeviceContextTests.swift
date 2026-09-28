// Copyright © 2026 Eigen Labs.
// Fresh-process hardware regression ONLY; no model load or physical coverage claim.
import Cmlx
import Foundation
import MLX
import MLXVLM
import XCTest
@_spi(Benchmarking) @testable import ProviderCore
#if canImport(Metal)
import Metal
#endif

final class MiMoV26WiredDeviceContextTests: XCTestCase {
    #if DEBUG && os(macOS) && canImport(Metal)
    private enum Failure: Error {
        case freshProcessRequired, unsupportedPlatform, metadataFixtureRequired
        case preparationRefused, startFailed, finalReceiptUnavailable, endFailed
        case setterFailed, baselineRestoreFailed, retainedBookkeeping
    }
    // One selector per process, even if an external harness repeats the class.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entered = false

    private final class OtherPolicy: WiredMemoryPolicy, @unchecked Sendable {
        let identity = UUID()
        var id: AnyHashable { AnyHashable(identity) }
        private let lock = NSLock()
        private var contexts: [Device] = []
        func canAdmit(baseline: Int, activeSizes: [Int], newSize: Int) -> Bool { true }
        func limit(baseline: Int, activeSizes: [Int]) -> Int {
            lock.withLock { contexts.append(Device.defaultDevice()) }
            return max(baseline, activeSizes.max() ?? 0)
        }
        var count: Int { lock.withLock { contexts.count } }
        func lastIs(_ device: Device) -> Bool { lock.withLock { contexts.last === device } }
    }

    /// A MUTATING diagnostic, not a getter: reapply the expected limit and
    /// inspect the actual prior returned by the C backend. No production call.
    private func observeByReapplying(_ limit: Int, phase: String) throws -> Int {
        var previous: size_t = 0
        let status = try withError { mlx_set_wired_limit(&previous,size_t(limit)) }
        guard status == 0, let value = Int(exactly:previous) else { throw Failure.setterFailed }
        print("MIMO_WIRED_TEST_MUTATING_OBSERVATION phase=\(phase) reapplied=\(limit) actualPrior=\(value)")
        return value
    }
    private func drain(_ device: Device) throws {
        // No model/array work is issued by this selector. Still use actual
        // checked synchronization; timeout/counter bookkeeping is not a fence.
        try Device.withDefaultDevice(device) {
            try withError { Stream.gpu.synchronize(); Stream.cpu.synchronize() }
        }
    }
    #endif

    /// Run separately with CASE=cpu-retire, gpu-retire, or cpu-retire-foreign.
    /// Root must provide a genuinely fresh isolated process and owned GPU lane.
    func testGPUStartRetiresInItsCapturedDeviceContextAndRestoresBaseline() async throws {
        #if DEBUG && os(macOS) && canImport(Metal)
        let environment = ProcessInfo.processInfo.environment
        guard environment["MIMO_V26_WIRED_DEVICE_CONTEXT_NATIVE"] == "1",
              let mode = environment["MIMO_V26_WIRED_DEVICE_CONTEXT_CASE"],
              ["cpu-retire","gpu-retire","cpu-retire-foreign"].contains(mode) else {
            throw XCTSkip("Fresh-process owned hardware selector requires explicit Device-context opt-ins")
        }
        guard Self.lock.withLock({
            if Self.entered { return false }; Self.entered = true; return true
        }) else { throw Failure.freshProcessRequired }
        guard #available(macOS 15, *), let metal = MTLCreateSystemDefaultDevice(),
              metal.supportsFamily(.metal3) else { throw Failure.unsupportedPlatform }
        guard let path = environment["MIMO_V26_WIRED_METADATA_FIXTURE"] else {
            throw Failure.metadataFixtureRequired
        }
        let gpu = Device(.gpu), retiring = mode == "gpu-retire" ? gpu : Device(.cpu)
        let registry = MiMoV26NativeLoadRegistry()
        var transaction: MiMoV26NativeLoadTransaction?
        var helper: MiMoV26WiredResidency?
        var retirement: MiMoV26NativeRetirementReceipt?
        var other: WiredMemoryTicket?
        var otherNeedsEnd = false
        var baseline: Int?
        var firstFailure: Error?
        var cleanupFailure: Error?
        let size = 4 << 20
        do {
            // This happens BEFORE accessing WiredMemoryManager.shared. Its
            // selected source starts with a cached0 baseline, not a getter.
            // Refuse a nonzero original baseline; cleanup restores it exactly.
            try drain(gpu)
            let original = try Device.withDefaultDevice(gpu) {
                try observeByReapplying(0,phase:"initial-baseline")
            }
            baseline = original
            guard original == 0 else { throw Failure.freshProcessRequired }

            // Actual strict metadata/permit owner, no loaded model or invented
            // serial receipt. The resulting real retirement is noNativeSubmission.
            let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory:URL(fileURLWithPath:path)))
            guard load.request.binding.tensorBytes > 0,
                  load.request.binding.tensorBytes <= 128 << 20 else { throw Failure.metadataFixtureRequired }
            let budget = GlobalKVCacheBudget(configReserveBytes:4 << 30)
            let tx = try registry.install(request:load.request,budget:budget,lifecycle:registry.openLifecycle())
            transaction = tx
            try tx.claimPermit()
            let prepared = Device.withDefaultDevice(gpu) {
                MiMoV26WiredResidency.makeForHardwareDeviceContextTesting(
                    transaction:tx,residentPayloadBytes:size)
            }
            guard case .prepared(let owner) = prepared else { throw Failure.preparationRefused }
            helper = owner
            let acquisition = try registry.launchOwnedTask(for:tx) {
                await Device.withDefaultDevice(gpu) { await owner.start() }
            }
            let started = try await acquisition.value
            await registry.joinOwnedTasksFromOutside(tx)
            guard started.phase == .held, started.managerStartValue == size,
                  !started.policyOnlyTest else { throw Failure.startFailed }
            try drain(gpu)
            let before = try Device.withDefaultDevice(gpu) {
                try observeByReapplying(size,phase:"after-supported-start")
            }
            XCTAssertEqual(before,size,"real GPU-start backend application is required")
            XCTAssertFalse(started.backendCoverageVerified)
            XCTAssertFalse(started.backendRestorationVerified)
            XCTAssertEqual(started.capturedDeviceType,.gpu)
            XCTAssertEqual(started.capturedDeviceDescription,gpu.description)

            let otherPolicy = OtherPolicy()
            var otherCallsBefore = 0
            if mode == "cpu-retire-foreign" {
                guard started.ownSafeCeilingBytes >= 8 << 20 else { throw Failure.preparationRefused }
                let ticket = WiredMemoryTicket(size:8 << 20,policy:otherPolicy,manager:.shared,kind:.active)
                other = ticket
                // Supported immediate-admission policy: preserve the handle
                // even if the C application error surfaces after installation.
                otherNeedsEnd = true
                let value = try await Device.withDefaultDevice(gpu) {
                    try await withError { errors in
                        let result = await ticket.start(); try errors.check(); return result
                    }
                }
                XCTAssertEqual(value,8 << 20)
                try drain(gpu)
                let prior = try Device.withDefaultDevice(gpu) {
                    try observeByReapplying(8 << 20,phase:"unrelated-ticket-active")
                }
                XCTAssertEqual(prior,8 << 20)
                otherCallsBefore = otherPolicy.count
            }

            let result: (MiMoV26NativeRetirementReceipt?, MiMoV26WiredResidency.EndResult) = await Device.withDefaultDevice(retiring) {
                let outcome = await tx.retire()
                guard case .retired(let receipt) = outcome else { return (nil,.retainedFault) }
                return (receipt,await owner.end(after:receipt))
            }
            guard let actual = result.0 else { throw Failure.finalReceiptUnavailable }
            retirement = actual
            XCTAssertEqual(actual.construction.completion,.noNativeSubmission)
            XCTAssertNil(actual.engine)
            guard result.1 == .ended else { throw Failure.endFailed }
            let ended = owner.snapshot()
            let expected = mode == "cpu-retire-foreign" ? 8 << 20 : original
            XCTAssertEqual(ended.managerEndValue,expected)
            XCTAssertFalse(ended.backendRestorationVerified)
            XCTAssertEqual(ended.capturedDeviceType,.gpu)
            XCTAssertEqual(ended.capturedDeviceDescription,started.capturedDeviceDescription)
            try drain(gpu)
            let restored = try Device.withDefaultDevice(gpu) {
                try observeByReapplying(expected,phase:"after-retiring-caller")
            }
            XCTAssertEqual(restored,expected,
                "original CPU-end bug returned cached0 but left backend at the start limit")
            if mode == "cpu-retire-foreign" {
                XCTAssertGreaterThan(otherPolicy.count,otherCallsBefore)
                XCTAssertTrue(otherPolicy.lastIs(gpu),
                    "remaining policy must recompute under the EXACT captured Device, not retiring CPU")
            }
            let again = await Device.withDefaultDevice(retiring) { await owner.end(after:actual) }
            XCTAssertEqual(again,.ended)
        } catch { firstFailure = error }

        // Cleanup is explicit even after refusal/assertion/backend error.
        // Preserve the first failure; cleanup success never relabels it a pass.
        var cleanupDrained = false
        do { try drain(gpu); cleanupDrained = true } catch { cleanupFailure = error }
        if let tx = transaction {
            await registry.joinOwnedTasksFromOutside(tx)
            if retirement == nil {
                if case .retired(let actual) = await tx.retire() { retirement = actual }
                else { cleanupFailure = Failure.finalReceiptUnavailable }
            }
            if let helper, let retirement, cleanupDrained {
                let ended = await helper.end(after:retirement)
                if ended != .ended {
                    _ = Unmanaged.passRetained(helper)
                    cleanupFailure = Failure.retainedBookkeeping
                }
            }
        }
        if let other, otherNeedsEnd, cleanupDrained {
            do {
                _ = try await Device.withDefaultDevice(gpu) {
                    try await withError { errors in
                        let value = await other.end(); try errors.check(); return value
                    }
                }
                otherNeedsEnd = false
            } catch { cleanupFailure = error }
        }
        do { try drain(gpu) } catch { cleanupDrained = false; cleanupFailure = error }
        if let baseline, cleanupDrained {
            do {
                _ = try Device.withDefaultDevice(gpu) {
                    try observeByReapplying(baseline,phase:"cleanup-restore-original")
                }
                try drain(gpu)
                let verified = try Device.withDefaultDevice(gpu) {
                    try observeByReapplying(baseline,phase:"cleanup-verify-original")
                }
                guard verified == baseline else { throw Failure.baselineRestoreFailed }
                try drain(gpu)
            } catch { cleanupFailure = error }
        }
        if let cleanupFailure {
            if let helper { _ = Unmanaged.passRetained(helper) }
            _ = Unmanaged.passRetained(registry)
            XCTFail("hardware diagnostic cleanup did not prove drain/restoration; no successful cell")
            if let firstFailure { throw firstFailure }
            throw cleanupFailure
        }
        if let firstFailure { throw firstFailure }
        withExtendedLifetime((registry,transaction,helper,other)) {}
        #else
        throw XCTSkip("Device-context hardware regression requires a separately bound DEBUG macOS/Metal build")
        #endif
    }
}
