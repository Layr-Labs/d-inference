import Foundation
import Testing

@testable import FanControlCore

@Suite("Fan helper leases")
struct FanLeaseControllerTests {
    @Test("hot active inference journals before engaging fans")
    func engagesTransactionally() throws {
        let events = EventLog()
        let driver = MockFanDriver(events: events)
        let journal = MockFanJournal(events: events)
        let controller = makeController(driver: driver, journal: journal)

        let lease = try controller.acquireLease(
            speedPercent: 90,
            triggerTemperatureCelsius: 40
        )
        let status = try controller.renewLease(
            lease,
            sequence: 1,
            inferenceActive: true
        )

        #expect(status.engaged)
        #expect(status.targetRPMs == [5_400])
        #expect(events.values == ["journal.mark", "driver.engage"])
    }

    @Test("idle inference restores and clears the recovery marker")
    func idleRestores() throws {
        let events = EventLog()
        let driver = MockFanDriver(events: events)
        let journal = MockFanJournal(events: events)
        let controller = makeController(driver: driver, journal: journal)
        let lease = try controller.acquireLease(
            speedPercent: 90,
            triggerTemperatureCelsius: 40
        )
        _ = try controller.renewLease(
            lease,
            sequence: 1,
            inferenceActive: true
        )

        let status = try controller.renewLease(
            lease,
            sequence: 2,
            inferenceActive: false
        )

        #expect(!status.engaged)
        #expect(Array(events.values.suffix(2)) == [
            "driver.restore",
            "journal.clear",
        ])
    }

    @Test("expired client lease restores before another lease starts")
    func expiryRestores() throws {
        let events = EventLog()
        let driver = MockFanDriver(events: events)
        let journal = MockFanJournal(events: events)
        var now = 100.0
        let controller = makeController(
            driver: driver,
            journal: journal,
            now: { now }
        )
        let first = try controller.acquireLease(
            speedPercent: 90,
            triggerTemperatureCelsius: 40
        )
        _ = try controller.renewLease(
            first,
            sequence: 1,
            inferenceActive: true
        )

        now += FanLeaseController.leaseTTLSeconds + 1
        let second = try controller.acquireLease(
            speedPercent: 90,
            triggerTemperatureCelsius: 40
        )

        #expect(second != first)
        #expect(!driver.isControlling)
        #expect(events.values.contains("driver.restore"))
    }

    @Test("a stale recovery marker is repaired before acquisition")
    func staleJournalRecovery() throws {
        let events = EventLog()
        let driver = MockFanDriver(events: events)
        let journal = MockFanJournal(
            recoveryRequired: true,
            events: events
        )
        let controller = makeController(driver: driver, journal: journal)

        _ = try controller.acquireLease(
            speedPercent: 90,
            triggerTemperatureCelsius: 40
        )

        #expect(events.values == ["driver.force", "journal.clear"])
        #expect(!journal.required)
    }

    @Test("only one lease and increasing sequence numbers are accepted")
    func leaseArbitration() throws {
        let driver = MockFanDriver()
        let journal = MockFanJournal()
        let controller = makeController(driver: driver, journal: journal)
        let lease = try controller.acquireLease(
            speedPercent: 90,
            triggerTemperatureCelsius: 40
        )

        #expect(throws: FanControlError.self) {
            try controller.acquireLease(
                speedPercent: 90,
                triggerTemperatureCelsius: 40
            )
        }
        _ = try controller.renewLease(
            lease,
            sequence: 2,
            inferenceActive: true
        )
        #expect(throws: FanControlError.self) {
            try controller.renewLease(
                lease,
                sequence: 2,
                inferenceActive: true
            )
        }
    }

    @Test("serious OS thermal pressure relinquishes manual control")
    func thermalPressureRestores() throws {
        let driver = MockFanDriver()
        let journal = MockFanJournal()
        let controller = makeController(driver: driver, journal: journal)
        let lease = try controller.acquireLease(
            speedPercent: 90,
            triggerTemperatureCelsius: 40
        )
        _ = try controller.renewLease(
            lease,
            sequence: 1,
            inferenceActive: true
        )
        driver.pressure = .serious

        let status = try controller.renewLease(
            lease,
            sequence: 2,
            inferenceActive: true
        )
        #expect(!status.engaged)
        #expect(driver.restoreCount == 1)
    }

    @Test("lease TTL starts after a slow hardware operation completes")
    func ttlStartsAfterOperation() throws {
        let driver = MockFanDriver()
        let journal = MockFanJournal()
        var now = 100.0
        driver.engageAction = {
            now = 115
        }
        let controller = makeController(
            driver: driver,
            journal: journal,
            now: { now }
        )
        let lease = try controller.acquireLease(
            speedPercent: 90,
            triggerTemperatureCelsius: 40
        )

        _ = try controller.renewLease(
            lease,
            sequence: 1,
            inferenceActive: true
        )
        now = 124

        #expect(throws: FanControlError.self) {
            try controller.acquireLease(
                speedPercent: 90,
                triggerTemperatureCelsius: 40
            )
        }
    }

    @Test("operation deadline interrupts hardware work and restores")
    func operationDeadlineRestores() throws {
        let events = EventLog()
        let driver = MockFanDriver(events: events)
        let journal = MockFanJournal(events: events)
        var now = 100.0
        driver.engageAction = {
            now += FanLeaseController.operationTimeoutSeconds + 1
        }
        let controller = makeController(
            driver: driver,
            journal: journal,
            now: { now }
        )
        let lease = try controller.acquireLease(
            speedPercent: 90,
            triggerTemperatureCelsius: 40
        )

        #expect(throws: FanControlError.self) {
            try controller.renewLease(
                lease,
                sequence: 1,
                inferenceActive: true
            )
        }
        #expect(!journal.required)
        #expect(events.values == [
            "journal.mark",
            "driver.force",
            "journal.clear",
        ])
    }

    @Test("ownership drift is not overwritten during cleanup")
    func ownershipDriftRelinquishes() throws {
        let events = EventLog()
        let driver = MockFanDriver(events: events)
        let journal = MockFanJournal(events: events)
        let controller = makeController(driver: driver, journal: journal)
        let lease = try controller.acquireLease(
            speedPercent: 90,
            triggerTemperatureCelsius: 40
        )
        _ = try controller.renewLease(
            lease,
            sequence: 1,
            inferenceActive: true
        )
        driver.maintainAction = {
            driver.isControlling = false
            driver.targetRPMs = []
            throw FanControlError.fanControlOwnershipLost
        }

        #expect(throws: FanControlError.self) {
            try controller.renewLease(
                lease,
                sequence: 2,
                inferenceActive: true
            )
        }
        #expect(Array(events.values.suffix(1)) == ["journal.clear"])
        #expect(!events.values.contains("driver.restore"))
        #expect(!events.values.contains("driver.force"))
    }

    private func makeController(
        driver: MockFanDriver,
        journal: MockFanJournal,
        now: @escaping () -> TimeInterval = { 100 }
    ) -> FanLeaseController {
        FanLeaseController(
            driver: driver,
            journal: journal,
            now: now
        )
    }
}

private final class EventLog {
    var values: [String] = []
}

private final class MockFanDriver: FanHardwareDriving {
    var isControlling = false
    var targetRPMs: [Int] = []
    var temperature = 60.0
    var pressure = FanThermalPressure.nominal
    var restoreCount = 0
    var engageAction: (() throws -> Void)?
    var maintainAction: (() throws -> Void)?
    private let events: EventLog?

    init(events: EventLog? = nil) {
        self.events = events
    }

    func sample(inferenceActive: Bool) -> FanCoolingSample {
        FanCoolingSample(
            inferenceActive: inferenceActive,
            hottestTemperatureCelsius: temperature,
            hottestSensor: "Tp09",
            thermalPressure: pressure
        )
    }

    func engage(
        speedPercent: Double,
        shouldStop: () -> Bool
    ) throws -> [Int] {
        events?.values.append("driver.engage")
        try engageAction?()
        if shouldStop() {
            throw FanControlError.interrupted
        }
        isControlling = true
        targetRPMs = [Int(6_000 * speedPercent / 100)]
        return targetRPMs
    }

    func maintain(shouldStop: () -> Bool) throws {
        try maintainAction?()
        if shouldStop() {
            throw FanControlError.interrupted
        }
    }

    func restoreAutomatic() throws {
        events?.values.append("driver.restore")
        restoreCount += 1
        isControlling = false
        targetRPMs = []
    }

    func forceAutomatic() throws {
        events?.values.append("driver.force")
        isControlling = false
        targetRPMs = []
    }
}

private final class MockFanJournal: FanRecoveryJournaling {
    var required: Bool
    private let events: EventLog?

    init(
        recoveryRequired: Bool = false,
        events: EventLog? = nil
    ) {
        required = recoveryRequired
        self.events = events
    }

    func recoveryRequired() throws -> Bool {
        required
    }

    func markRecoveryRequired() throws {
        events?.values.append("journal.mark")
        required = true
    }

    func clear() throws {
        events?.values.append("journal.clear")
        required = false
    }
}
