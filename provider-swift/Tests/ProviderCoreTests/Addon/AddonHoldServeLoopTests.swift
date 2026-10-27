import Foundation
import Testing

@testable import ProviderCore

/// End to end against the loopback coordinator: an add-on holds through the
/// real socket, the provider stays registered, leaves routing on its draining
/// heartbeat without a `provider_drain` barrier, survives a planned reconnect
/// with busy fields in the fresh `register`, and returns on release.
@Suite("Add-on hold serve loop", .serialized)
struct AddonHoldServeLoopTests {
    @Test func holdLeavesRoutingSurvivesAPlannedReconnectAndReturnsOnRelease() async throws {
        let fixture = try await ServeLoopFixture.make()
        let runtime = try AddonRuntimeFixture()
        defer { runtime.remove() }
        let peer = AddonPeer(identifier: "io.darkbloom.sandbox")
        await fixture.loop.useAddonHoldForTesting(paths: runtime.paths, clock: AddonTestClock(),
                                                  authenticate: { _ in peer }, serving: true)
        let task = fixture.start()
        let firstRegister = try await fixture.awaitRegistration()
        #expect(firstRegister.busy == nil)
        let client = try AddonSocketClient(path: runtime.paths.socket.path)
        let hello = try client.request(#"{"v":1,"op":"hello"}"#)
        #expect(hello["capabilities"] as? [String] == ["hold.v1"])

        let hold = try client.request(#"{"v":1,"op":"hold","addon":"io.darkbloom.sandbox","vm_bytes":4294967296,"lease_seconds":120}"#)
        let holdID = try #require(hold["hold_id"] as? String)
        #expect(hold["state"] as? String == "draining")

        let draining = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.heartbeats.contains { $0.status == .draining && $0.busy?.addon == "io.darkbloom.sandbox" }
        })
        #expect(draining.drainBarriers.isEmpty)
        let heldStatus = try await addonEventually {
            ((try? client.request(#"{"v":1,"op":"status","hold_id":"\#(holdID)"}"#))?["state"] as? String) == "held"
        }
        #expect(heldStatus)
        #expect(await fixture.loop.modelLoadingResidentIDs().isEmpty)
        #expect(fixture.mock.snapshot().drainBarriers.isEmpty)
        #expect(fixture.mock.snapshot().registers.count == 1)

        // Routed work is refused with the no-fault reroute while held.
        try await fixture.pushChatRequest(requestId: "held-request")
        let rejected = try #require(try await fixture.mock.waitForSnapshot {
            $0.inferenceErrors.contains { $0.requestId == "held-request" }
        })
        let error = try #require(rejected.inferenceErrors.first { $0.requestId == "held-request" })
        #expect(error.statusCode == 503 && error.errorReason == .draining)

        // A planned reconnect keeps the hold: the fresh register carries the
        // busy fields and the next heartbeat is still draining.
        await fixture.loop.requestPlannedReconnect()
        let reconnected = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(20)) {
            $0.registers.count == 2
        })
        #expect(reconnected.registers[1].busy?.addon == "io.darkbloom.sandbox")
        #expect(reconnected.registers[1].busy?.reason == .addon)
        let heartbeatsBeforeRelease = fixture.mock.snapshot().heartbeats.count
        #expect(await fixture.loop.state.refusingNewWork)
        #expect(await fixture.loop.addonHoldDrainOwner() == .addonHold)

        let released = try client.request(#"{"v":1,"op":"release","hold_id":"\#(holdID)"}"#)
        #expect(released["state"] as? String == "released" && released["ok"] as? Bool == true)
        let idle = try #require(try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.heartbeats.dropFirst(heartbeatsBeforeRelease).contains { $0.status == .idle && $0.busy == nil }
        })
        #expect(idle.registers.count == 2)
        #expect(await !fixture.loop.state.refusingNewWork)
        #expect(await fixture.stop(task))
    }
}
