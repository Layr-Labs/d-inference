// Copyright © 2026 Eigen Labs.
// Copyright 2025 oMLX contributors (persistent-residency policy intent).
// SPDX-License-Identifier: Apache-2.0
// Persistent-residency intent from jundot/omlx #3970, fba858555b7a8c367d9a472f5df8d268097eef15.
// This is a shared-manager adaptation, not the upstream direct-setter policy.
import Cmlx
import Foundation
import MLX
import MLXVLM
#if canImport(Metal)
import Metal
#endif

/// Default standing residency, acceleration only. Neither a model-memory
/// permit nor a promise that specific buffers are wired. The native
/// transaction owns this handle.
///
/// Without a standing residency set, every command buffer must make MiMo's
/// ~161 GiB of expert tensors resident again; under the memory pressure of a
/// 256 GiB host the driver keeps unwiring them and decode collapses (measured
/// ~0.4 tok/s versus ~38 tok/s with residency on an M3 Ultra). The bounded
/// ceiling below still leaves max(16 GiB, 10%) of physical memory unwired.
final class MiMoV26WiredResidency: @unchecked Sendable {
    static let environmentFlag = "DARKBLOOM_MIMO_PERSISTENT_WIRED_RESIDENCY"
    /// Values that roll back to per-command-buffer residency. Unset or any
    /// other value (including the former opt-in `1`) keeps the default.
    static let rollbackValues: Set<String> = ["0", "false", "no", "off"]
    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let raw = environment[environmentFlag] else { return true }
        return !rollbackValues.contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    enum Refusal: String, Sendable {
        case unsupportedPlatform, unsupportedStream, missingRecommendation, invalidReceipt, invalidBounds
    }
    enum Preparation {
        case disabled, unsupported(Refusal), prepared(MiMoV26WiredResidency)
    }
    enum Phase: String, Sendable {
        case prepared, starting, held, ending, ended, unsupported, retainedFault
    }
    enum EndResult: Equatable, Sendable {
        case ended, pendingStart, pendingEnd, foreignReceipt, retainedFault
    }
    struct Snapshot: Sendable {
        let phase: Phase
        let residentPayloadBytes: Int
        let ownSafeCeilingBytes: Int
        let managerStartValue: Int?
        let managerEndValue: Int?
        let cancelledWhenStartReturned: Bool
        let policyOnlyTest: Bool
        let capturedDeviceType: DeviceType?
        // Public SDK description includes the device index; Device has no
        // public index getter. Keep it opaque instead of guessing/parsing.
        let capturedDeviceDescription: String?
        // Always false: manager cached/applied values are not backend getters.
        let backendCoverageVerified = false
        let backendRestorationVerified = false
        var managerValueExceedsOwnCeiling: Bool {
            (managerStartValue ?? 0) > ownSafeCeilingBytes
        }
    }

    struct Bounds: Equatable, Sendable {
        let physicalBytes: UInt64
        let recommendedBytes: UInt64
        let loadCapBytes: UInt64

        var safeCeiling: Int? {
            guard physicalBytes > 0, recommendedBytes > 0, loadCapBytes > 0 else { return nil }
            // Round UP the ten-percent reserve; never under-reserve a byte.
            let tenth = physicalBytes / 10 + (physicalBytes % 10 == 0 ? 0 : 1)
            let reserve = max(UInt64(16) << 30, tenth)
            guard physicalBytes > reserve else { return nil }
            let value = min(min(physicalBytes - reserve, recommendedBytes), min(loadCapBytes, UInt64(Int.max)))
            return value > 0 ? Int(value) : nil
        }
    }

    /// All MiMo slots share this exact policy instance/group in production.
    /// Entries retain only scalar-cap readers, never model arrays or a second
    /// manager. Each reader is the existing process-ledger policy snapshot.
    final class Policy: WiredMemoryPolicy, @unchecked Sendable {
        static let shared = Policy()
        var id: AnyHashable { AnyHashable("darkbloom.mimo-v26.resident-payload.v1") }
        private let lock = NSLock()
        private var ceilings: [UUID: @Sendable () -> Int] = [:]

        func register(_ id: UUID, ceiling: @escaping @Sendable () -> Int) {
            lock.withLock { precondition(ceilings[id] == nil); ceilings[id] = ceiling }
        }
        func remove(_ id: UUID) { lock.withLock { _ = ceilings.removeValue(forKey: id) } }
        var registeredCount: Int { lock.withLock { ceilings.count } }

        static func summed(_ sizes: [Int]) -> Int {
            sizes.reduce(0) { sum, size in
                let next = sum.addingReportingOverflow(max(0, size))
                return next.overflow ? Int.max : next.partialValue
            }
        }
        static func desired(baseline: Int, activeSizes: [Int], ceiling: Int) -> Int {
            // Preserve a pre-existing/cached baseline, even if it is already
            // above our ceiling. Never label that case reserve enforcement.
            max(max(0, baseline), min(max(0, ceiling), summed(activeSizes)))
        }
        func canAdmit(baseline: Int, activeSizes: [Int], newSize: Int) -> Bool {
            // Not admission authority: always install immediately. Avoid the
            // manager's cancelled-waiter return that cannot prove admission.
            true
        }
        func limit(baseline: Int, activeSizes: [Int]) -> Int {
            let readers = lock.withLock { Array(ceilings.values) }
            let ceiling = readers.map { max(0, $0()) }.min() ?? 0
            return Self.desired(baseline: baseline, activeSizes: activeSizes, ceiling: ceiling)
        }
    }

    private let transactionID, sessionID: UUID
    private let lifecycle: MiMoV26NativeLifecycle
    private let residentPayloadBytes: Int
    private let ceiling: @Sendable () -> Int
    private let policy: Policy
    private let ticket: WiredMemoryTicket
    private let policyOnlyTest: Bool
    private let lock = NSLock()
    private var phase: Phase = .prepared
    private var startValue: Int?
    private var endValue: Int?
    private var lateCancellation = false
    // The manager resolves backend support from the caller's TaskLocal Device.
    // Keep the exact start handle, not merely .gpu or a thread-bound Stream.
    private var managerDevice: Device?
    private var managerDeviceType: DeviceType?
    private var managerDeviceDescription: String?
    #if DEBUG
    private var afterManagerStartForTesting: (@Sendable () async throws -> Void)?
    #endif

    private init(transactionID: UUID, sessionID: UUID, lifecycle: MiMoV26NativeLifecycle,
                 residentPayloadBytes: Int, ceiling: @escaping @Sendable () -> Int,
                 policy: Policy, manager: WiredMemoryManager, policyOnlyTest: Bool) {
        self.transactionID = transactionID; self.sessionID = sessionID; self.lifecycle = lifecycle
        self.residentPayloadBytes = residentPayloadBytes; self.ceiling = ceiling
        self.policy = policy; self.policyOnlyTest = policyOnlyTest
        ticket = WiredMemoryTicket(size: residentPayloadBytes, policy: policy, manager: manager, kind: .active)
        policy.register(ticket.id, ceiling: ceiling)
    }

    /// Called after exact returned-receipt settlement, within the TX's existing
    /// owned load operation. Store the returned helper in TX BEFORE awaiting
    /// start; even cancelled/faulted late returns must keep their real owner.
    static func prepare(transactionID: UUID, lifecycle: MiMoV26NativeLifecycle,
                        request: MiMoV26SerialLoadRequest, receipt: MiMoV26SerialLoadReceipt,
                        budget: GlobalKVCacheBudget, enabled: Bool = isEnabled()) -> Preparation {
        guard enabled else { return .disabled }
        guard receipt.sessionID == request.sessionID, receipt.binding == request.binding,
              request.binding.tensorBytes > 0,
              receipt.materializedSourcePayloadBytes == UInt64(request.binding.tensorBytes),
              receipt.materializedSourcePayloadBytes <= UInt64(Int.max),
              !receipt.externalComponentsLoaded else { return .unsupported(.invalidReceipt) }
        guard platformSupported else { return .unsupported(.unsupportedPlatform) }
        guard gpuStreamAndManagerDevice() else { return .unsupported(.unsupportedStream) }
        let recommended: Int?
        do { recommended = try withError { GPU.maxRecommendedWorkingSetBytes() } }
        catch { return .unsupported(.missingRecommendation) }
        guard let recommended, recommended > 0 else { return .unsupported(.missingRecommendation) }
        let physical = budget.physicalMemoryBytes
        let readCeiling: @Sendable () -> Int = {
            Bounds(physicalBytes: physical, recommendedBytes: UInt64(recommended),
                   loadCapBytes: budget.processLedger.policySnapshot().capBytes).safeCeiling ?? 0
        }
        guard readCeiling() > 0 else { return .unsupported(.invalidBounds) }
        return .prepared(.init(transactionID: transactionID, sessionID: request.sessionID,
            lifecycle: lifecycle, residentPayloadBytes: Int(receipt.materializedSourcePayloadBytes),
            ceiling: readCeiling, policy: .shared, manager: .shared, policyOnlyTest: false))
    }

    private static var platformSupported: Bool {
        #if os(macOS) && canImport(Metal)
        guard #available(macOS 15, *), let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.supportsFamily(.metal3)
        #else
        return false
        #endif
    }
    private static func gpuStreamAndManagerDevice() -> Bool {
        // Metadata query only; an unsupported/error result never starts a
        // ticket and must not escape through MLX's default fatal handler.
        (try? withError {
            guard Device.defaultDevice().deviceType == .gpu else { return false }
            var device = mlx_device_new()
            defer { mlx_device_free(device) }
            var type = MLX_CPU
            return mlx_stream_get_device(&device, StreamOrDevice.default.ctx) == 0
                && mlx_device_get_type(&type, device) == 0 && type == MLX_GPU
        }) ?? false
    }

    func snapshot() -> Snapshot {
        let ceilingNow = ceiling()
        return lock.withLock {
            .init(phase: phase, residentPayloadBytes: residentPayloadBytes,
                  ownSafeCeilingBytes: ceilingNow, managerStartValue: startValue,
                  managerEndValue: endValue, cancelledWhenStartReturned: lateCancellation,
                  policyOnlyTest: policyOnlyTest, capturedDeviceType:managerDeviceType,
                  capturedDeviceDescription:managerDeviceDescription)
        }
    }

    /// No Task.checkCancellation and no cancellation-handler end. The selected
    /// manager installs a supported, immediate-admission ticket even for a
    /// task cancelled while its actor call was queued. TX rechecks afterwards.
    @discardableResult
    func start() async -> Snapshot {
        let claimed = lock.withLock { () -> Bool in
            guard phase == .prepared else { return false }
            phase = .starting; return true
        }
        guard claimed else { return snapshot() }
        if !policyOnlyTest && (!Self.platformSupported || !Self.gpuStreamAndManagerDevice()) {
            lock.withLock { phase = .unsupported }
            policy.remove(ticket.id)
            return snapshot()
        }
        let device = Device.defaultDevice()
        let deviceMetadata = try? withError { (device.deviceType,device.description) }
        // Store before the manager await: cancellation/application failure may
        // occur after the real ticket is installed and must retain this owner.
        lock.withLock {
            managerDevice = device; managerDeviceType = deviceMetadata?.0
            managerDeviceDescription = deviceMetadata?.1
        }
        do {
            try await Device.withDefaultDevice(device) {
                try await withError { errors in
                    let value = await ticket.start()
                    lock.withLock { startValue = value }
                    try errors.check()
                }
            }
            #if DEBUG
            if let hook = afterManagerStartForTesting { try await hook() }
            #endif
            lock.withLock { phase = .held; lateCancellation = Task.isCancelled }
        } catch {
            // Ticket is already installed before its backend application.
            // Do not end it here or orphan a late acquisition on a real fault.
            lock.withLock { phase = .retainedFault; lateCancellation = Task.isCancelled }
        }
        return snapshot()
    }

    /// Only the actual final TX receipt can authorize end. Its initializer is
    /// file-private to the existing transaction; no new receipt/lifecycle exists.
    /// This method neither changes permits nor reports physical reclamation.
    func end(after receipt: MiMoV26NativeRetirementReceipt) async -> EndResult {
        guard receipt.transactionID == transactionID, receipt.sessionID == sessionID,
              receipt.lifecycle == lifecycle else { return .foreignReceipt }
        let decision: EndResult? = lock.withLock {
            switch phase {
            case .starting: return .pendingStart
            case .ending: return .pendingEnd
            case .ended: return .ended
            case .retainedFault: return .retainedFault
            case .prepared, .unsupported:
                phase = .ended; return .ended // no manager start occurred
            case .held:
                phase = .ending; return nil
            }
        }
        if let decision {
            if decision == .ended { policy.remove(ticket.id) }
            return decision
        }
        guard let device = lock.withLock({ managerDevice }) else {
            // A held ticket without its start context must stay owned; never
            // end under the retiring caller's potentially unsupported Device.
            lock.withLock { phase = .retainedFault }
            return .retainedFault
        }
        do {
            try await Device.withDefaultDevice(device) {
                try await withError { errors in
                    let value = await ticket.end()
                    lock.withLock { endValue = value }
                    try errors.check()
                }
            }
            lock.withLock { phase = .ended }
            policy.remove(ticket.id)
            return .ended
        } catch {
            // Manager bookkeeping may already have removed the ticket and
            // emitted baselineRestored despite an apply failure. No retry of
            // end(), no false restoration proof, no permit/credit operation.
            lock.withLock { phase = .retainedFault }
            return .retainedFault
        }
    }

    #if DEBUG
    /// Host-only policy/lifetime tests. Caller scopes Device.cpu and uses the
    /// existing DEBUG manager's policy-only configuration; never fake Metal.
    static func makeForPolicyOnlyTesting(transaction: MiMoV26NativeLoadTransaction,
        residentPayloadBytes: Int, ceiling: @escaping @Sendable () -> Int,
        policy: Policy, manager: WiredMemoryManager,
        afterManagerStart: (@Sendable () async throws -> Void)? = nil) -> MiMoV26WiredResidency {
        precondition(Device.defaultDevice().deviceType == .cpu && residentPayloadBytes > 0)
        let value = MiMoV26WiredResidency(transactionID: transaction.id,
            sessionID: transaction.request.sessionID, lifecycle: transaction.lifecycle,
            residentPayloadBytes: residentPayloadBytes, ceiling: ceiling,
            policy: policy, manager: manager, policyOnlyTest: true)
        value.afterManagerStartForTesting = afterManagerStart
        return value
    }

    /// Separate fresh-process GPU Device regression only. It deliberately uses
    /// a bounded synthetic ticket, not a forged serial-load/coverage receipt.
    /// Actual transaction retirement is still required by end(after:).
    static func makeForHardwareDeviceContextTesting(
        transaction: MiMoV26NativeLoadTransaction, residentPayloadBytes: Int
    ) -> Preparation {
        guard platformSupported else { return .unsupported(.unsupportedPlatform) }
        guard gpuStreamAndManagerDevice() else { return .unsupported(.unsupportedStream) }
        guard residentPayloadBytes > 0, residentPayloadBytes <= 8 << 20 else {
            return .unsupported(.invalidBounds)
        }
        let recommended: Int?
        do { recommended = try withError { GPU.maxRecommendedWorkingSetBytes() } }
        catch { return .unsupported(.missingRecommendation) }
        guard let recommended, recommended > 0 else { return .unsupported(.missingRecommendation) }
        let budget = transaction.budget, physical = budget.physicalMemoryBytes
        let ceiling: @Sendable () -> Int = {
            min(8 << 20, Bounds(physicalBytes:physical, recommendedBytes:UInt64(recommended),
                loadCapBytes:budget.processLedger.policySnapshot().capBytes).safeCeiling ?? 0)
        }
        guard ceiling() >= residentPayloadBytes else { return .unsupported(.invalidBounds) }
        return .prepared(.init(transactionID:transaction.id, sessionID:transaction.request.sessionID,
            lifecycle:transaction.lifecycle, residentPayloadBytes:residentPayloadBytes,
            ceiling:ceiling, policy:.shared, manager:.shared, policyOnlyTest:false))
    }
    #endif
}
