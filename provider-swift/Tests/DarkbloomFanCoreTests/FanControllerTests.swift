import Foundation
import Testing

@testable import DarkbloomFanCore

@Suite("Transactional fan controller")
struct FanControllerTests {
    private func makeController(
        backend: FakeSMCBackend,
        brand: String = "Apple M4 Max",
        timing: FanControlTiming = FanControlTiming(
            ftstSettleSeconds: 0,
            retryDelaySeconds: 0,
            manualModeAttempts: 3,
            automaticRestoreAttempts: 1,
            verificationAttempts: 2,
            sleep: { _ in }
        )
    ) throws -> TransactionalFanController {
        let inventory = try FanHardwareReader(backend: backend).discover(brandString: brand)
        backend.resetOperations()
        return TransactionalFanController(
            backend: backend,
            inventory: inventory,
            timing: timing
        )
    }

    @Test("direct mode applies per-fan percentage and explicit restore is idempotent")
    func directModeAndRestore() async throws {
        let backend = makeFanBackend()
        let controller = try makeController(backend: backend)
        let session = try await controller.engage(speedPercent: 80)

        #expect(session.targetRPMByFan[0] == 4_000)
        #expect(session.targetRPMByFan[1] == 4_400)
        #expect(!session.ownsFtst)
        #expect(try backend.uint8("F0Md") == 1)
        #expect(try backend.uint8("F1Md") == 1)
        #expect(abs(try backend.float("F0Tg") - 4_000) < 0.001)
        #expect(abs(try backend.float("F1Tg") - 4_400) < 0.001)

        try await controller.restoreAutomatic()
        #expect(try backend.uint8("F0Md") == 0)
        #expect(try backend.uint8("F1Md") == 0)
        #expect(await controller.currentSession() == nil)
        try await controller.restoreAutomatic()
    }

    @Test("takeover never lowers an existing actual or target RPM")
    func takeoverFloor() async throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.setFloat("F0Ac", 4_100)
        backend.setFloat("F0Tg", 4_500)
        let controller = try makeController(backend: backend)

        let session = try await controller.engage(speedPercent: 60)
        #expect(session.targetRPMByFan[0] == 4_500)
        #expect(abs(try backend.float("F0Tg") - 4_500) < 0.001)
        try await controller.restoreAutomatic()
    }

    @Test("takeover re-reads a target raised after the initial snapshot")
    func takeoverRereadsLateTargetRaise() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        let controller = try makeController(backend: backend)
        backend.installReadHook { key, count in
            if key == "F0Tg", count == 1 {
                backend.setFloat("F0Tg", 4_500)
            }
        }

        let session = try await controller.engage(speedPercent: 60)
        #expect(session.targetRPMByFan[0] == 4_500)
        #expect(abs(try backend.float("F0Tg") - 4_500) < 0.001)
        try await controller.restoreAutomatic()
    }

    @Test("takeover re-reads actual RPM raised after the initial snapshot")
    func takeoverRereadsLateActualRaise() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        let controller = try makeController(backend: backend)
        backend.installReadHook { key, count in
            if key == "F0Tg", count == 1 {
                backend.setFloat("F0Ac", 4_700)
            }
        }

        let session = try await controller.engage(speedPercent: 60)
        #expect(session.targetRPMByFan[0] == 4_700)
        #expect(abs(try backend.float("F0Tg") - 4_700) < 0.001)
        try await controller.restoreAutomatic()
    }

    @Test("Ftst fallback still re-reads the final takeover floor")
    func ftstFallbackRereadsLateTargetRaise() async throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.queue([
            .failBefore(.firmwareRejected(
                operation: .writeBytes,
                key: "F0Md",
                result: 0x82
            )),
            .succeed,
        ], for: "F0Md")
        backend.installWriteHook { key, bytes in
            if key == "Ftst", bytes == [1] {
                backend.setFloat("F0Tg", 4_600)
            }
        }
        let controller = try makeController(backend: backend)

        let session = try await controller.engage(speedPercent: 60)
        #expect(session.ownsFtst)
        #expect(session.targetRPMByFan[0] == 4_600)
        #expect(abs(try backend.float("F0Tg") - 4_600) < 0.001)
        try await controller.restoreAutomatic()
    }

    @Test("a late takeover floor above maximum aborts to Auto")
    func takeoverRejectsLateFloorAboveMaximum() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        let controller = try makeController(backend: backend)
        backend.installReadHook { key, count in
            if key == "F0Tg", count == 1 {
                backend.setFloat("F0Ac", 5_100)
            }
        }

        let error = await captureControllerError {
            _ = try await controller.engage(speedPercent: 60)
        }
        #expect(error == .takeoverFloorExceedsMaximum(
            index: 0,
            floor: 5_100,
            maximum: 5_000
        ))
        #expect(try backend.uint8("F0Md") == FanMode.automatic.rawValue)
        #expect(await controller.currentSession() == nil)
    }

    @Test("an automatic RPM above maximum refuses takeover before writes")
    func invalidTakeoverFloor() async throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.setFloat("F0Ac", 5_100)
        let controller = try makeController(backend: backend)

        let error = await captureControllerError {
            _ = try await controller.engage(speedPercent: 80)
        }
        #expect(error == .takeoverFloorExceedsMaximum(
            index: 0,
            floor: 5_100,
            maximum: 5_000
        ))
        #expect(!backend.operations.contains(where: {
            if case .write = $0 { return true }
            return false
        }))
    }

    @Test("duplicate fan indices are rejected without trapping or writing")
    func duplicateFanInventory() async throws {
        let backend = makeFanBackend(fanCount: 1)
        let discovered = try FanHardwareReader(backend: backend).discover(
            brandString: "Apple M4"
        )
        let fan = try #require(discovered.fans.first)
        let duplicate = FanInventory(
            chipFamily: discovered.chipFamily,
            fans: [fan, fan],
            gpuTemperatureKeys: discovered.gpuTemperatureKeys,
            ftstKey: discovered.ftstKey
        )
        backend.resetOperations()
        let controller = TransactionalFanController(
            backend: backend,
            inventory: duplicate,
            timing: FanControlTiming(
                ftstSettleSeconds: 0,
                retryDelaySeconds: 0,
                manualModeAttempts: 1,
                automaticRestoreAttempts: 1,
                verificationAttempts: 1,
                sleep: { _ in }
            )
        )

        let error = await captureControllerError {
            _ = try await controller.engage(speedPercent: 80)
        }
        #expect(error == .duplicateFanIndex(0))
        #expect(!backend.operations.contains(where: {
            if case .write = $0 { return true }
            return false
        }))
    }

    @Test("pre-existing manual mode is foreign and is never overwritten")
    func foreignManualControl() async throws {
        let backend = makeFanBackend()
        backend.setUI8("F1Md", 1)
        let controller = try makeController(backend: backend)
        let callback = CallbackCounter()

        let error = await captureControllerError {
            _ = try await controller.engage(
                speedPercent: 80,
                recordOwnership: { _ in callback.increment() }
            )
        }
        #expect(error == .foreignManualControl(indices: [1]))
        #expect(callback.value == 0)
        #expect(try backend.uint8("F1Md") == 1)
        #expect(!backend.operations.contains(where: {
            if case .write = $0 { return true }
            return false
        }))
    }

    @Test("ownership journal expands one fan immediately before each takeover")
    func ownershipExpandsPerFan() async throws {
        let backend = makeFanBackend(includeFtst: false)
        let controller = try makeController(backend: backend)
        let recorder = OwnershipRecorder()

        let session = try await controller.engage(
            speedPercent: 80,
            recordOwnership: recorder.record
        )

        #expect(session.targetRPMByFan.keys.sorted() == [0, 1])
        #expect(recorder.values == [
            FanControlOwnership(fanIndices: [0], ownsFtst: false),
            FanControlOwnership(fanIndices: [0, 1], ownsFtst: false),
        ])
        try await controller.restoreAutomatic()
    }

    @Test("a foreign manual claim after the initial scan is never overwritten")
    func concurrentForeignFanIsRechecked() async throws {
        let backend = makeFanBackend(includeFtst: false)
        let controller = try makeController(backend: backend)
        let recorder = OwnershipRecorder()
        backend.installReadHook { key, count in
            if key == "F1Md", count == 1 {
                backend.setUI8("F1Md", 1)
            }
        }

        let error = await captureControllerError {
            _ = try await controller.engage(
                speedPercent: 80,
                recordOwnership: recorder.record
            )
        }

        #expect(error == .foreignManualControl(indices: [1]))
        #expect(try backend.uint8("F0Md") == 0)
        #expect(try backend.uint8("F1Md") == 1)
        #expect(!backend.operations.contains(.write("F1Md", [1])))
        #expect(recorder.values == [
            FanControlOwnership(fanIndices: [0], ownsFtst: false),
            FanControlOwnership(fanIndices: [], ownsFtst: false),
        ])
    }

    @Test("a foreign claim during journal fsync narrows ownership before aborting")
    func foreignFanDuringJournalWriteIsPreserved() async throws {
        let backend = makeFanBackend(includeFtst: false)
        let controller = try makeController(backend: backend)
        let recorder = OwnershipRecorder { ownership in
            if ownership == FanControlOwnership(
                fanIndices: [0, 1],
                ownsFtst: false
            ) {
                backend.setUI8("F1Md", 1)
            }
        }

        let error = await captureControllerError {
            _ = try await controller.engage(
                speedPercent: 80,
                recordOwnership: recorder.record
            )
        }

        #expect(error == .foreignManualControl(indices: [1]))
        #expect(try backend.uint8("F0Md") == 0)
        #expect(try backend.uint8("F1Md") == 1)
        #expect(!backend.operations.contains(.write("F1Md", [1])))
        #expect(recorder.values == [
            FanControlOwnership(fanIndices: [0], ownsFtst: false),
            FanControlOwnership(fanIndices: [0, 1], ownsFtst: false),
            FanControlOwnership(fanIndices: [0], ownsFtst: false),
            FanControlOwnership(fanIndices: [], ownsFtst: false),
        ])
    }

    @Test("controller independently enforces the 60 through 90 percent range")
    func controllerSpeedBounds() async throws {
        for invalid in [59.9, 90.1, Double.nan] {
            let backend = makeFanBackend(fanCount: 1)
            let controller = try makeController(backend: backend)
            let error = await captureControllerError {
                _ = try await controller.engage(speedPercent: invalid)
            }
            guard let error, case .invalidSpeedPercent(let value) = error else {
                Issue.record("expected invalid speed error, got \(String(describing: error))")
                continue
            }
            if invalid.isNaN {
                #expect(value.isNaN)
            } else {
                #expect(value == invalid)
            }
            #expect(!backend.operations.contains(where: {
                if case .write = $0 { return true }
                return false
            }))
        }
    }

    @Test("firmware rejection uses owned Ftst fallback and clears it on restore")
    func ftstFallback() async throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.queue([
            .failBefore(.firmwareRejected(
                operation: .writeBytes,
                key: "F0Md",
                result: 0x82
            )),
            .succeed,
        ], for: "F0Md")
        let controller = try makeController(backend: backend)

        let session = try await controller.engage(speedPercent: 80)
        #expect(session.ownsFtst)
        #expect(try backend.uint8("Ftst") == 1)
        #expect(try backend.uint8("F0Md") == 1)

        try await controller.restoreAutomatic()
        #expect(try backend.uint8("F0Md") == 0)
        #expect(try backend.uint8("Ftst") == 0)
    }

    @Test("Ftst journal preserves only fans already at a possible write boundary")
    func ftstJournalPreservesExactFanSet() async throws {
        let backend = makeFanBackend()
        backend.queue([
            .failBefore(.firmwareRejected(
                operation: .writeBytes,
                key: "F0Md",
                result: 0x82
            )),
            .succeed,
        ], for: "F0Md")
        let controller = try makeController(backend: backend)
        let recorder = OwnershipRecorder()

        let session = try await controller.engage(
            speedPercent: 80,
            recordOwnership: recorder.record
        )

        #expect(session.ownsFtst)
        let ftstIntent = try #require(
            recorder.values.first(where: { $0.ownsFtst })
        )
        #expect(ftstIntent.fanIndices == [0])
        try await controller.restoreAutomatic()
    }

    @Test("owned Ftst reset during setup is reasserted before success returns")
    func ftstIsVerifiedAtTransactionEnd() async throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.queue([
            .failBefore(.firmwareRejected(
                operation: .writeBytes,
                key: "F0Md",
                result: 0x82
            )),
            .succeed,
        ], for: "F0Md")
        backend.installWriteHook { key, _ in
            if key == "F0Tg" {
                backend.setUI8("Ftst", 0)
            }
        }
        let controller = try makeController(backend: backend)

        let session = try await controller.engage(speedPercent: 80)
        #expect(session.ownsFtst)
        #expect(try backend.uint8("Ftst") == 1)
        #expect(backend.operations.filter { $0 == .write("Ftst", [1]) }.count == 2)
        try await controller.restoreAutomatic()
    }

    @Test("pre-existing Ftst is never claimed or cleared")
    func foreignFtst() async throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.setUI8("Ftst", 1)
        backend.queue([.failBefore(.firmwareRejected(
            operation: .writeBytes,
            key: "F0Md",
            result: 0x82
        ))], for: "F0Md")
        let controller = try makeController(backend: backend)

        let error = await captureControllerError {
            _ = try await controller.engage(speedPercent: 80)
        }
        #expect(error == .foreignFtst(rawValue: 1))
        #expect(try backend.uint8("Ftst") == 1)
        #expect(try backend.uint8("F0Md") == 0)
        #expect(!backend.operations.contains(.write("Ftst", [0])))
    }

    @Test("Ftst acquired concurrently during direct setup aborts and preserves foreign ownership")
    func concurrentForeignFtstIsDetected() async throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.installWriteHook { key, bytes in
            if key == "F0Md", bytes == [1] {
                backend.setUI8("Ftst", 1)
            }
        }
        let controller = try makeController(backend: backend)

        let error = await captureControllerError {
            _ = try await controller.engage(speedPercent: 80)
        }
        #expect(error == .foreignFtst(rawValue: 1))
        #expect(try backend.uint8("F0Md") == 0)
        #expect(try backend.uint8("Ftst") == 1)
        #expect(!backend.operations.contains(.write("Ftst", [0])))
    }

    @Test("permission denial never attempts the Ftst bypass")
    func permissionFailureDoesNotUseFtst() async throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.queue([.failBefore(.notPrivileged(
            operation: .writeBytes,
            key: "F0Md"
        ))], for: "F0Md")
        let controller = try makeController(backend: backend)

        let error = await captureControllerError {
            _ = try await controller.engage(speedPercent: 80)
        }
        #expect(error == .smc(.notPrivileged(operation: .writeBytes, key: "F0Md")))
        #expect(!backend.operations.contains(.write("Ftst", [1])))
        #expect(try backend.uint8("Ftst") == 0)
    }

    @Test("a mode write that mutates then throws is still rolled back")
    func uncertainModeWriteRollsBack() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        backend.queue([
            .failAfter(.injectedFailure("mode accepted then failed")),
            .succeed,
        ], for: "F0Md")
        let controller = try makeController(backend: backend)

        let error = await captureControllerError {
            _ = try await controller.engage(speedPercent: 80)
        }
        #expect(error == .smc(.injectedFailure("mode accepted then failed")))
        #expect(try backend.uint8("F0Md") == 0)
        #expect(await controller.currentSession() == nil)
    }

    @Test("silent manual-mode rejection is detected without Ftst and restored")
    func modeReadbackVerification() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        backend.queue([.ignore, .succeed], for: "F0Md")
        let controller = try makeController(backend: backend)

        let error = await captureControllerError {
            _ = try await controller.engage(speedPercent: 80)
        }
        #expect(error == .modeVerificationFailed(index: 0, rawValue: 0))
        #expect(try backend.uint8("F0Md") == 0)
    }

    @Test("an uncertain Ftst write is always cleared during rollback")
    func uncertainFtstWriteRollsBack() async throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.queue([.failBefore(.firmwareRejected(
            operation: .writeBytes,
            key: "F0Md",
            result: 0x82
        ))], for: "F0Md")
        backend.queue([
            .failAfter(.injectedFailure("Ftst accepted then failed")),
            .succeed,
        ], for: "Ftst")
        let controller = try makeController(backend: backend)

        let error = await captureControllerError {
            _ = try await controller.engage(speedPercent: 80)
        }
        #expect(error == .smc(.injectedFailure("Ftst accepted then failed")))
        #expect(try backend.uint8("F0Md") == 0)
        #expect(try backend.uint8("Ftst") == 0)
        #expect(await controller.currentSession() == nil)
    }

    @Test("a target failure after mutation restores every touched fan")
    func targetFailureRollsBackAllFans() async throws {
        let backend = makeFanBackend()
        backend.queue([.failAfter(.injectedFailure("target accepted then failed"))], for: "F1Tg")
        let controller = try makeController(backend: backend)

        let error = await captureControllerError {
            _ = try await controller.engage(speedPercent: 80)
        }
        #expect(error == .smc(.injectedFailure("target accepted then failed")))
        #expect(try backend.uint8("F0Md") == 0)
        #expect(try backend.uint8("F1Md") == 0)
        #expect(await controller.currentSession() == nil)
    }

    @Test("silent target rejection is detected and restored")
    func targetReadbackVerification() async throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.queue([.ignore], for: "F0Tg")
        let controller = try makeController(backend: backend)

        let error = await captureControllerError {
            _ = try await controller.engage(speedPercent: 80)
        }
        #expect(error == .targetVerificationFailed(
            index: 0,
            expected: 4_000,
            actual: 1_400
        ))
        #expect(try backend.uint8("F0Md") == 0)
    }

    @Test("failed rollback retains uncertain fan state for a later retry")
    func rollbackFailureCanBeRetried() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        backend.queue([
            .succeed,
            .failBefore(.injectedFailure("first automatic restore failed")),
            .succeed,
        ], for: "F0Md")
        backend.queue([.failBefore(.injectedFailure("target write failed"))], for: "F0Tg")
        let controller = try makeController(backend: backend)

        let error = await captureControllerError {
            _ = try await controller.engage(speedPercent: 80)
        }
        guard let error, case .rollbackFailed(let primary, let failures) = error else {
            Issue.record("expected rollback failure, got \(String(describing: error))")
            return
        }
        #expect(primary == .smc(.injectedFailure("target write failed")))
        #expect(failures.count == 1)
        #expect(failures[0].fanIndex == 0)
        #expect(await controller.currentSession() != nil)

        try await controller.restoreAutomatic()
        #expect(try backend.uint8("F0Md") == 0)
        #expect(await controller.currentSession() == nil)
    }

    @Test("failed journal narrowing retains conservative in-memory ownership")
    func journalNarrowingFailureRetainsBroadOwnership() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        backend.queue([
            .failBefore(.injectedFailure("target failed")),
        ], for: "F0Tg")
        let controller = try makeController(backend: backend)
        let recorder = OwnershipRecorder { ownership in
            if ownership.fanIndices.isEmpty {
                throw OwnershipRecorderError.injected
            }
        }

        let error = await captureControllerError {
            _ = try await controller.engage(
                speedPercent: 80,
                recordOwnership: recorder.record
            )
        }
        guard let error,
              case .rollbackFailed(_, let failures) = error
        else {
            Issue.record("expected rollback failure, got \(String(describing: error))")
            return
        }
        #expect(failures.contains(where: { $0.step == .persistOwnership }))
        #expect(await controller.isControlling)
        #expect(try backend.uint8("F0Md") == FanMode.automatic.rawValue)

        try await controller.restoreAutomatic()
        #expect(await controller.currentSession() == nil)
    }

    @Test("rollback continues to later fans after an earlier restore fails")
    func rollbackAttemptsEveryFan() async throws {
        let backend = makeFanBackend()
        backend.queue([
            .succeed,
            .failBefore(.injectedFailure("fan zero restore failed")),
        ], for: "F0Md")
        backend.queue([.failBefore(.injectedFailure("fan one target failed"))], for: "F1Tg")
        let controller = try makeController(backend: backend)
        let recorder = OwnershipRecorder()

        let error = await captureControllerError {
            _ = try await controller.engage(
                speedPercent: 80,
                recordOwnership: recorder.record
            )
        }
        guard let error, case .rollbackFailed(_, let failures) = error else {
            Issue.record("expected rollback failure, got \(String(describing: error))")
            return
        }
        #expect(failures.contains(where: { $0.fanIndex == 0 }))
        #expect(try backend.uint8("F1Md") == 0)
        #expect(backend.operations.contains(.write("F1Md", [0])))
        #expect(recorder.values.last == FanControlOwnership(
            fanIndices: [0],
            ownsFtst: false
        ))
    }

    @Test("rollback verifies automatic mode instead of trusting a successful write")
    func rollbackModeReadbackFailureCanBeRetried() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        backend.queue([
            .succeed,
            .replace([1]),
            .succeed,
        ], for: "F0Md")
        backend.queue([.failBefore(.injectedFailure("target failed"))], for: "F0Tg")
        let controller = try makeController(backend: backend)

        let error = await captureControllerError {
            _ = try await controller.engage(speedPercent: 80)
        }
        guard let error, case .rollbackFailed(_, let failures) = error else {
            Issue.record("expected rollback failure, got \(String(describing: error))")
            return
        }
        #expect(failures == [FanRollbackFailure(
            fanIndex: 0,
            step: .restoreMode,
            error: .modeNotAutomatic(rawValue: 1)
        )])
        #expect((await controller.currentSession()) != nil)

        try await controller.restoreAutomatic()
        #expect(try backend.uint8("F0Md") == 0)
        #expect(await controller.currentSession() == nil)
    }

    @Test("uncertain Ftst ownership survives failed clear and can be retried")
    func ftstRollbackRetry() async throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.queue([
            .failBefore(.firmwareRejected(operation: .writeBytes, key: "F0Md", result: 0x82)),
            .succeed,
            .succeed,
        ], for: "F0Md")
        backend.queue([
            .succeed,
            .failBefore(.injectedFailure("Ftst clear failed")),
            .succeed,
        ], for: "Ftst")
        backend.queue([.failBefore(.injectedFailure("target failed"))], for: "F0Tg")
        let controller = try makeController(backend: backend)
        let recorder = OwnershipRecorder()

        let error = await captureControllerError {
            _ = try await controller.engage(
                speedPercent: 80,
                recordOwnership: recorder.record
            )
        }
        guard let error, case .rollbackFailed(_, let failures) = error else {
            Issue.record("expected rollback failure, got \(String(describing: error))")
            return
        }
        #expect(failures.contains(where: { $0.step == .clearFtst }))
        #expect((await controller.currentSession())?.ownsFtst == true)
        #expect(recorder.values.last == FanControlOwnership(
            fanIndices: [],
            ownsFtst: true
        ))

        try await controller.restoreAutomatic()
        #expect(try backend.uint8("Ftst") == 0)
        #expect(await controller.currentSession() == nil)
    }

    @Test("automatic restore retries stale M4 mode and Ftst readback")
    func automaticRestoreRetriesStaleReadback() async throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.queue([
            .failBefore(.firmwareRejected(
                operation: .writeBytes,
                key: "F0Md",
                result: 0x82
            )),
            .succeed,
        ], for: "F0Md")
        let controller = try makeController(
            backend: backend,
            timing: FanControlTiming(
                ftstSettleSeconds: 0,
                retryDelaySeconds: 0,
                manualModeAttempts: 3,
                automaticRestoreAttempts: 3,
                verificationAttempts: 1,
                sleep: { _ in }
            )
        )
        let session = try await controller.engage(speedPercent: 80)
        #expect(session.ownsFtst)

        backend.queue([.replace([1]), .succeed], for: "F0Md")
        backend.queue([.replace([1]), .succeed], for: "Ftst")
        backend.installWriteHook { key, bytes in
            if key == "Ftst", bytes == [0] {
                backend.setUI8("F0Md", FanMode.manual.rawValue)
            }
        }

        try await controller.restoreAutomatic()

        #expect(try backend.uint8("F0Md") == FanMode.automatic.rawValue)
        #expect(try backend.uint8("Ftst") == 0)
        #expect(await controller.currentSession() == nil)
        #expect(backend.operations.filter {
            $0 == .write("F0Md", [FanMode.automatic.rawValue])
        }.count == 3)
        #expect(backend.operations.filter {
            $0 == .write("Ftst", [0])
        }.count == 2)
    }

    @Test("maintain never treats orphaned Ftst uncertainty as a healthy session")
    func maintainClearsOrphanedFtst() async throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.queue([
            .failBefore(.firmwareRejected(operation: .writeBytes, key: "F0Md", result: 0x82)),
            .succeed,
            .succeed,
        ], for: "F0Md")
        backend.queue([
            .succeed,
            .failBefore(.injectedFailure("first Ftst clear failed")),
            .succeed,
        ], for: "Ftst")
        backend.queue([.failBefore(.injectedFailure("target failed"))], for: "F0Tg")
        let controller = try makeController(backend: backend)
        _ = await captureControllerError {
            _ = try await controller.engage(speedPercent: 80)
        }
        #expect((await controller.currentSession())?.ownsFtst == true)

        let maintainError = await captureControllerError {
            _ = try await controller.maintain()
        }
        #expect(maintainError == .notControlling)
        #expect(try backend.uint8("Ftst") == 0)
        #expect(await controller.currentSession() == nil)
    }

    @Test("maintain requires an existing owned session")
    func maintainRequiresSession() async throws {
        let backend = makeFanBackend(fanCount: 1)
        let controller = try makeController(backend: backend)
        let error = await captureControllerError {
            _ = try await controller.maintain()
        }
        #expect(error == .notControlling)
        #expect(!backend.operations.contains(where: {
            if case .write = $0 { return true }
            return false
        }))
    }

    @Test("reassert recovers a firmware-reclaimed mode and target")
    func reassertsReclaimedSession() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        let controller = try makeController(backend: backend)
        _ = try await controller.engage(speedPercent: 80)
        backend.setUI8("F0Md", 3)
        backend.setFloat("F0Tg", 0)
        backend.resetOperations()

        let session = try await controller.reassert()
        #expect(session.targetRPMByFan[0] == 4_000)
        #expect(try backend.uint8("F0Md") == 1)
        #expect(abs(try backend.float("F0Tg") - 4_000) < 0.001)
        #expect(backend.operations.contains(.write("F0Md", [1])))
        #expect(backend.operations.contains(.write(
            "F0Tg",
            try SMCValue.float32Bytes(4_000, key: "F0Tg")
        )))
    }

    @Test("maintain rewrites a reclaimed target without toggling a valid mode")
    func rewritesOnlyReclaimedTarget() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        let controller = try makeController(backend: backend)
        _ = try await controller.engage(speedPercent: 80)
        backend.setFloat("F0Tg", 0)
        backend.resetOperations()

        _ = try await controller.maintain()
        #expect(abs(try backend.float("F0Tg") - 4_000) < 0.001)
        #expect(!backend.operations.contains(.write("F0Md", [1])))
    }

    @Test("maintain adopts a higher live manual target and never lowers it")
    func maintainPreservesHigherManualTarget() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        let controller = try makeController(backend: backend)
        _ = try await controller.engage(speedPercent: 80)
        backend.setFloat("F0Tg", 4_500)
        backend.resetOperations()

        let raised = try await controller.maintain()
        #expect(raised.targetRPMByFan[0] == 4_500)
        #expect(abs(try backend.float("F0Tg") - 4_500) < 0.001)
        #expect(!backend.operations.contains(where: {
            if case .write("F0Tg", _) = $0 { return true }
            return false
        }))

        backend.setFloat("F0Tg", 0)
        backend.resetOperations()
        let restored = try await controller.maintain()
        #expect(restored.targetRPMByFan[0] == 4_500)
        #expect(abs(try backend.float("F0Tg") - 4_500) < 0.001)
    }

    @Test("maintain preserves a higher target while reclaiming system mode")
    func maintainPreservesHigherTargetAcrossModeRepair() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        let controller = try makeController(backend: backend)
        _ = try await controller.engage(speedPercent: 80)
        backend.setUI8("F0Md", FanMode.system.rawValue)
        backend.setFloat("F0Tg", 4_500)
        backend.resetOperations()

        let session = try await controller.maintain()
        #expect(session.targetRPMByFan[0] == 4_500)
        #expect(try backend.uint8("F0Md") == FanMode.manual.rawValue)
        #expect(abs(try backend.float("F0Tg") - 4_500) < 0.001)
    }

    @Test("an impossible live maintenance target fails safe to Auto")
    func maintainRejectsTargetAboveMaximum() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        let controller = try makeController(backend: backend)
        _ = try await controller.engage(speedPercent: 80)
        backend.setFloat("F0Tg", 5_100)

        let error = await captureControllerError {
            _ = try await controller.maintain()
        }
        #expect(error == .takeoverFloorExceedsMaximum(
            index: 0,
            floor: 5_100,
            maximum: 5_000
        ))
        #expect(try backend.uint8("F0Md") == FanMode.automatic.rawValue)
        #expect(await controller.currentSession() == nil)
    }

    @Test("a negative live maintenance target fails safe to Auto")
    func maintainRejectsNegativeTarget() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        let controller = try makeController(backend: backend)
        _ = try await controller.engage(speedPercent: 80)
        backend.setFloat("F0Tg", -1)

        let error = await captureControllerError {
            _ = try await controller.maintain()
        }
        guard let error,
              case .hardware(.invalidFanRPM(
                  index: 0,
                  field: "F0Tg",
                  value: let value
              )) = error
        else {
            Issue.record("expected invalid target error, got \(String(describing: error))")
            return
        }
        #expect(value == -1)
        #expect(try backend.uint8("F0Md") == FanMode.automatic.rawValue)
        #expect(await controller.currentSession() == nil)
    }

    @Test("maintain reacquires an owned Ftst gate reset by sleep")
    func reacquiresFtstAfterSleep() async throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.queue([
            .failBefore(.firmwareRejected(
                operation: .writeBytes,
                key: "F0Md",
                result: 0x82
            )),
            .succeed,
        ], for: "F0Md")
        let controller = try makeController(backend: backend)
        _ = try await controller.engage(speedPercent: 80)
        backend.setUI8("Ftst", 0)
        backend.setUI8("F0Md", 3)
        backend.setFloat("F0Tg", 0)
        backend.resetOperations()

        let session = try await controller.maintain()
        #expect(session.ownsFtst)
        #expect(try backend.uint8("Ftst") == 1)
        #expect(try backend.uint8("F0Md") == 1)
        #expect(abs(try backend.float("F0Tg") - 4_000) < 0.001)
        #expect(backend.operations.contains(.write("Ftst", [1])))
    }

    @Test("maintain failure restores the whole session instead of leaving it partial")
    func maintainFailureRestoresSession() async throws {
        let backend = makeFanBackend()
        let controller = try makeController(backend: backend)
        _ = try await controller.engage(speedPercent: 80)
        backend.setFloat("F1Tg", 0)
        backend.queue([.failAfter(.injectedFailure("maintenance target failed"))], for: "F1Tg")

        let error = await captureControllerError {
            _ = try await controller.maintain()
        }
        #expect(error == .smc(.injectedFailure("maintenance target failed")))
        #expect(try backend.uint8("F0Md") == 0)
        #expect(try backend.uint8("F1Md") == 0)
        #expect(await controller.currentSession() == nil)
    }

    @Test("actor serialization prevents restore from interleaving with engage")
    func concurrentCallsSerialize() async throws {
        let backend = makeFanBackend(fanCount: 1, includeFtst: false)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        backend.installWriteHook { key, bytes in
            if key == "F0Md", bytes == [1] {
                entered.signal()
                release.wait()
            }
        }
        let controller = try makeController(backend: backend)

        let engage = Task.detached {
            try await controller.engage(speedPercent: 80)
        }
        #expect(await waitForSemaphore(entered, timeout: .now() + 2) == .success)
        let restore = Task.detached {
            try await controller.restoreAutomatic()
        }
        release.signal()
        _ = try await engage.value
        try await restore.value

        let writes = backend.operations.compactMap { operation -> (SMCKey, [UInt8])? in
            if case .write(let key, let bytes) = operation { return (key, bytes) }
            return nil
        }
        let targetWriteIndex = writes.firstIndex { pair in pair.0 == "F0Tg" }
        let automaticWriteIndex = writes.firstIndex { pair in
            pair.0 == "F0Md" && pair.1 == [0]
        }
        let targetWrite = try #require(targetWriteIndex)
        let automaticWrite = try #require(automaticWriteIndex)
        #expect(automaticWrite > targetWrite)
        #expect(await controller.currentSession() == nil)
    }
}

private func captureControllerError(
    _ operation: () async throws -> Void
) async -> FanControllerError? {
    do {
        try await operation()
        Issue.record("expected fan controller operation to fail")
        return nil
    } catch let error as FanControllerError {
        return error
    } catch {
        Issue.record("unexpected error type: \(error)")
        return nil
    }
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: timeout))
        }
    }
}

private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class OwnershipRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [FanControlOwnership] = []
    private let onRecord: @Sendable (FanControlOwnership) throws -> Void

    init(
        onRecord: @escaping @Sendable (FanControlOwnership) throws -> Void = { _ in }
    ) {
        self.onRecord = onRecord
    }

    var values: [FanControlOwnership] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ ownership: FanControlOwnership) throws {
        lock.lock()
        recorded.append(ownership)
        lock.unlock()
        try onRecord(ownership)
    }
}

private enum OwnershipRecorderError: Error {
    case injected
}
