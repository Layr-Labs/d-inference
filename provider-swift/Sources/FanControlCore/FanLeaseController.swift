import Dispatch
import Foundation
import Darwin

public final class FanLeaseController: @unchecked Sendable {
    public static let leaseTTLSeconds: TimeInterval = 10

    private struct Lease {
        let id: UUID
        let configuration: FanCoolingConfiguration
        var lastSequence: UInt64
        var expiresAt: TimeInterval
    }

    private let queue = DispatchQueue(
        label: "io.darkbloom.provider.fan-helper.lease"
    )
    private let driver: FanHardwareDriving
    private let journal: FanRecoveryJournaling
    private let now: () -> TimeInterval
    private let log: (String) -> Void
    private var lease: Lease?
    private var timer: DispatchSourceTimer!

    public convenience init() throws {
        #if arch(arm64)
        guard geteuid() == 0 else {
            throw FanControlError.rootRequired
        }
        #else
        throw FanControlError.unsupportedArchitecture
        #endif

        let journal = FanRecoveryJournal()
        let recoveryRequired = try journal.recoveryRequired()
        let driver = try SMCFanHardwareDriver(
            recoverStaleControl: recoveryRequired
        )
        if recoveryRequired {
            try journal.clear()
        }
        self.init(
            driver: driver,
            journal: journal,
            now: Self.monotonicSeconds,
            log: { message in
                FileHandle.standardError.write(
                    Data(("fan-helper: \(message)\n").utf8)
                )
            }
        )
    }

    init(
        driver: FanHardwareDriving,
        journal: FanRecoveryJournaling,
        now: @escaping () -> TimeInterval,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.driver = driver
        self.journal = journal
        self.now = now
        self.log = log

        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(
            deadline: .now() + 1,
            repeating: 1,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                try self.expireLeaseIfNeeded()
            } catch {
                self.log(
                    "automatic recovery failed: \(error.localizedDescription)"
                )
            }
        }
        timer.resume()
    }

    deinit {
        timer.cancel()
    }

    public func acquireLease(
        speedPercent: Double,
        triggerTemperatureCelsius: Double
    ) throws -> UUID {
        try queue.sync {
            try expireLeaseIfNeeded()
            guard lease == nil else {
                throw FanControlError.leaseBusy
            }
            try recoverPendingControl()

            let configuration = try FanCoolingConfiguration(
                speedPercent: speedPercent,
                triggerTemperatureCelsius: triggerTemperatureCelsius
            )
            let id = UUID()
            lease = Lease(
                id: id,
                configuration: configuration,
                lastSequence: 0,
                expiresAt: now() + Self.leaseTTLSeconds
            )
            return id
        }
    }

    public func renewLease(
        _ id: UUID,
        sequence: UInt64,
        inferenceActive: Bool
    ) throws -> FanLeaseStatus {
        try queue.sync {
            try expireLeaseIfNeeded()
            guard var current = lease, current.id == id else {
                throw FanControlError.leaseNotFound
            }
            guard sequence > current.lastSequence else {
                throw FanControlError.staleLeaseSequence
            }
            current.lastSequence = sequence
            current.expiresAt = now() + Self.leaseTTLSeconds
            lease = current

            let sample = driver.sample(
                inferenceActive: inferenceActive
            )
            do {
                switch FanCoolingPolicy.decide(
                    configuration: current.configuration,
                    isBoosted: driver.isControlling,
                    sample: sample
                ) {
                case .engage:
                    try journal.markRecoveryRequired()
                    _ = try driver.engage(
                        speedPercent: current.configuration.speedPercent
                    )
                case .maintain:
                    if driver.isControlling {
                        try driver.maintain()
                    }
                case .release:
                    try restoreOwnedControl()
                }
            } catch let operationError {
                lease = nil
                do {
                    try restoreOwnedControl()
                } catch let restoreError {
                    throw FanControlError.operationAndRestoreFailed(
                        operation: operationError.localizedDescription,
                        restore: restoreError.localizedDescription
                    )
                }
                throw operationError
            }

            return FanLeaseStatus(
                engaged: driver.isControlling,
                temperatureCelsius: sample.hottestTemperatureCelsius,
                temperatureSensor: sample.hottestSensor,
                targetRPMs: driver.targetRPMs
            )
        }
    }

    public func releaseLease(_ id: UUID) throws {
        try queue.sync {
            guard let current = lease, current.id == id else {
                throw FanControlError.leaseNotFound
            }
            lease = nil
            try restoreOwnedControl()
        }
    }

    public func restoreAutomatic() throws {
        try queue.sync {
            lease = nil
            try driver.forceAutomatic()
            try journal.clear()
        }
    }

    public func shutdown() throws {
        try queue.sync {
            lease = nil
            try restoreOwnedControl()
            timer.cancel()
        }
    }

    private func expireLeaseIfNeeded() throws {
        guard let current = lease, now() >= current.expiresAt else {
            if lease == nil {
                try recoverPendingControl()
            }
            return
        }

        lease = nil
        log("lease expired; restoring automatic fan control")
        try restoreOwnedControl()
    }

    private func recoverPendingControl() throws {
        if driver.isControlling || (try journal.recoveryRequired()) {
            try restoreOwnedControl()
        }
    }

    private func restoreOwnedControl() throws {
        if driver.isControlling {
            try driver.restoreAutomatic()
        } else if try journal.recoveryRequired() {
            try driver.forceAutomatic()
        }
        try journal.clear()
    }

    private static func monotonicSeconds() -> TimeInterval {
        struct Timebase {
            static let value: mach_timebase_info_data_t = {
                var info = mach_timebase_info_data_t()
                mach_timebase_info(&info)
                return info
            }()
        }
        let ticks = mach_continuous_time()
        let nanos = Double(ticks) *
            Double(Timebase.value.numer) /
            Double(Timebase.value.denom)
        return nanos / 1_000_000_000
    }
}
