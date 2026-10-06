import DarkbloomFanProtocol
import Foundation
import Testing

@testable import darkbloom

/// Leases point at a temp helper path and a launchd service name that nothing
/// registers, so no real helper receives a lease.
@Suite("Fan activity lease")
struct FanActivityLeaseTests {
    private struct Fixture {
        let directory: URL
        let helper: URL
        let serviceName = "io.darkbloom.fan.test.\(UUID().uuidString)"

        init(installHelper: Bool) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("fan-lease-\(UUID().uuidString)")
            helper = directory.appendingPathComponent("io.darkbloom.fan-helper")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if installHelper {
                try Data("helper".utf8).write(to: helper)
            }
        }

        func lease() -> FanActivityLease {
            FanActivityLease(providerVersion: "0.0.0-test", helperURL: helper, machServiceName: serviceName)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private struct LeaseTestError: Error {}

    @Test("without an installed helper the lease runs but opens no connection")
    func noHelperNoConnection() async throws {
        let fixture = try Fixture(installHelper: false)
        defer { fixture.remove() }
        let lease = fixture.lease()

        await lease.start()
        #expect(await lease.running)
        #expect(await !lease.hasConnection)

        await lease.stop()
        #expect(await !lease.running)
    }

    @Test("with a helper installed, start is idempotent and stop closes the connection")
    func helperConnectsAndStops() async throws {
        let fixture = try Fixture(installHelper: true)
        defer { fixture.remove() }
        let lease = fixture.lease()

        // The connection can drop at any time because no service answers,
        // so only the stop result is checked for it.
        await lease.start()
        #expect(await lease.running)
        await lease.start()
        #expect(await lease.running)

        await lease.stop()
        #expect(await !lease.running)
        #expect(await !lease.hasConnection)
        await lease.stop()
        #expect(await !lease.running)
    }

    @Test("a lost helper connection is dropped")
    func lostConnectionIsDropped() async throws {
        let fixture = try Fixture(installHelper: true)
        defer { fixture.remove() }
        let lease = fixture.lease()

        await lease.start()
        let deadline = Date().addingTimeInterval(10)
        while await lease.hasConnection, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(await !lease.hasConnection)
        #expect(await lease.running)
        await lease.stop()
    }

    @Test("a rejected renewal is reported once, and an accepted one clears it")
    func renewalReplies() async throws {
        let lease = FanActivityLease(providerVersion: "0.0.0-test")
        let rejected = try FanIPCCoding.encode(FanIPCReply(ok: false, message: "provider is not signed"))
        let rejectedWithoutMessage = try FanIPCCoding.encode(FanIPCReply(ok: false))
        let accepted = try FanIPCCoding.encode(FanIPCReply(ok: true))

        await lease.handleRenewalReply(rejected)
        #expect(await lease.lastReportedError == "provider is not signed")
        await lease.handleRenewalReply(rejected)
        #expect(await lease.lastReportedError == "provider is not signed")

        await lease.handleRenewalReply(accepted)
        #expect(await lease.lastReportedError == nil)

        await lease.handleRenewalReply(rejectedWithoutMessage)
        #expect(await lease.lastReportedError == "fan helper rejected the provider lease")

        await lease.handleRenewalReply(Data("not json".utf8))
        let invalid = await lease.lastReportedError
        #expect(invalid?.hasPrefix("invalid fan helper lease reply: ") == true)
    }

    @Test("the lease wrapper returns the value and stops the lease")
    func wrapperReturnsValue() async throws {
        let fixture = try Fixture(installHelper: true)
        defer { fixture.remove() }
        let lease = fixture.lease()

        let value = await withFanActivityLease(lease) {
            await lease.running ? 42 : 0
        }

        #expect(value == 42)
        #expect(await !lease.running)
        #expect(await !lease.hasConnection)
    }

    @Test("the lease wrapper stops the lease and rethrows an error")
    func wrapperRethrows() async throws {
        let fixture = try Fixture(installHelper: false)
        defer { fixture.remove() }
        let lease = fixture.lease()

        await #expect(throws: LeaseTestError.self) {
            try await withFanActivityLease(lease) {
                #expect(await lease.running)
                throw LeaseTestError()
            }
        }
        #expect(await !lease.running)
    }

    @Test("a cancelled task stops the lease")
    func cancellationStopsLease() async throws {
        let fixture = try Fixture(installHelper: false)
        defer { fixture.remove() }
        let lease = fixture.lease()

        let task = Task {
            try await withFanActivityLease(lease) {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        let deadline = Date().addingTimeInterval(10)
        while await !lease.running, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        _ = await task.result

        let stopDeadline = Date().addingTimeInterval(10)
        while await lease.running, Date() < stopDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await !lease.running)
    }
}
