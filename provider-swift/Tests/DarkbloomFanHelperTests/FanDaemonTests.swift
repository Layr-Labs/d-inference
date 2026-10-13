import DarkbloomFanCore
import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation
import Testing

@testable import DarkbloomFanHelper

@Suite("Fan helper daemon")
struct FanDaemonTests {
    @Test("provider lease is required and disconnect restores Auto")
    func providerLeaseLifecycle() async throws {
        let harness = try makeFanDaemonHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).mode == .waitingForProvider)
        #expect(harness.backend.byte("F0Md") == 0)

        let session = UUID()
        let reply = await harness.daemon.renewLease(
            sessionID: session,
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        #expect(reply.ok)
        await harness.daemon.tick()

        let active = await harness.daemon.status()
        #expect(active.mode == .manual)
        #expect(active.providerActive)
        #expect(harness.backend.byte("F0Md") == 1)
        #expect(harness.backend.journalExistedBeforeFirstManualWrite)
        #expect(FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
        let journal = try FanDurableFile.readJSON(
            FanSessionJournal.self,
            from: harness.paths.sessionJournal,
            requireRootOwnership: false
        )
        #expect(!journal.ownsFtst)

        await harness.daemon.sessionInvalidated(session)
        #expect(harness.backend.byte("F0Md") == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
        #expect((await harness.daemon.status()).mode == .waitingForProvider)

        _ = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 1)
    }

    @Test("stale sessions cannot release a replacement lease", arguments: [false, true])
    func replacementLeaseIgnoresStaleSession(explicitRelease: Bool) async throws {
        let harness = try makeFanDaemonHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let oldSession = UUID()
        let currentSession = UUID()
        _ = await harness.daemon.renewLease(
            sessionID: oldSession,
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()
        harness.clock.advance(by: 10)
        _ = await harness.daemon.renewLease(
            sessionID: currentSession,
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        if explicitRelease {
            #expect((await harness.daemon.releaseLease(sessionID: oldSession)).ok)
        } else {
            await harness.daemon.sessionInvalidated(oldSession)
        }
        harness.clock.advance(by: FanIPC.leaseDurationSeconds - 1)
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).providerActive)
        #expect(harness.backend.byte("F0Md") == 1)

        // Expiry belongs to the replacement session, including its exact boundary.
        harness.clock.advance(by: 1)
        await harness.daemon.tick()
        #expect(!(await harness.daemon.status()).providerActive)
        #expect(harness.backend.byte("F0Md") == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
    }

    @Test("expired lease restores Auto without a disconnect callback")
    func leaseExpiry() async throws {
        let harness = try makeFanDaemonHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let session = UUID()
        _ = await harness.daemon.renewLease(
            sessionID: session,
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 1)

        harness.clock.advance(by: FanIPC.leaseDurationSeconds + 1)
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 0)
        #expect(!(await harness.daemon.status()).providerActive)
    }

    @Test("protocol mismatch never grants a lease")
    func protocolMismatch() async throws {
        let harness = try makeFanDaemonHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let reply = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion + 1,
            providerVersion: "0.7.9"
        )
        #expect(!reply.ok)
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 0)
        #expect((await harness.daemon.status()).mode == .waitingForProvider)
    }

    @Test("sleep restores Auto and requires a fresh provider renewal")
    func sleepRecovery() async throws {
        let harness = try makeFanDaemonHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        _ = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 1)

        await harness.daemon.prepareForSleep()
        #expect(harness.backend.byte("F0Md") == 0)
        let sleepingRenewal = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        #expect(!sleepingRenewal.ok)
        await harness.daemon.didWake()
        let status = await harness.daemon.status()
        #expect(!status.providerActive)
        #expect(status.mode == .waitingForProvider)
    }

    @Test("transient Auto failure is retried while ownership remains")
    func restoreRetry() async throws {
        let harness = try makeFanDaemonHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let session = UUID()
        _ = await harness.daemon.renewLease(
            sessionID: session,
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 1)

        harness.backend.failNextAutomaticRestore()
        await harness.daemon.sessionInvalidated(session)
        #expect(harness.backend.byte("F0Md") == 1)
        #expect(FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))

        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
    }

    @Test("administrator restore latches leases off until helper restart")
    func administrativeDisableLatch() async throws {
        let harness = try makeFanDaemonHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        _ = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 1)

        let restored = await harness.daemon.emergencyRestore()
        #expect(restored.ok)
        #expect(harness.backend.byte("F0Md") == 0)
        let renewal = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        #expect(!renewal.ok)
        #expect(!(await harness.daemon.status()).enabled)
    }

    @Test("Ftst ownership is journaled immediately before the first write")
    func ftstIntentPrecedesWrite() async throws {
        let harness = try makeFanDaemonHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.backend.rejectNextManualWrite()

        _ = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()

        #expect(harness.backend.byte("Ftst") == 1)
        #expect(harness.backend.journalClaimedFtstBeforeFirstFtstWrite)
        let journal = try FanDurableFile.readJSON(
            FanSessionJournal.self,
            from: harness.paths.sessionJournal,
            requireRootOwnership: false
        )
        #expect(journal.ownsFtst)
    }

    @Test("maintenance never journals or clears a foreign Ftst gate")
    func maintenancePreservesForeignFtst() async throws {
        let harness = try makeFanDaemonHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        _ = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 1)

        harness.clock.advance(by: 6)
        harness.backend.setByte("F0Md", to: FanMode.system.rawValue)
        harness.backend.rejectNextManualWrite(claimingFtst: true)
        await harness.daemon.tick()

        #expect(harness.backend.byte("F0Md") == 0)
        #expect(harness.backend.byte("Ftst") == 1)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
    }
}
