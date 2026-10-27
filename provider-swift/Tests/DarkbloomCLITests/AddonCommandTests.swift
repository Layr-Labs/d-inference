import ArgumentParser
import Foundation
import Testing
@testable import darkbloom
@testable import ProviderCore

@Suite struct AddonCommandTests {
    private static let hold = AddonHoldView(holdId: "h", addon: "io.darkbloom.sandbox", state: "held",
                                            sinceMs: 1_800_000_000_000, leaseExpiresAtMs: 1_800_000_060_000, vmBytes: 0)

    @Test func parsesSubcommandsAndBoundsTheLease() throws {
        #expect(try Darkbloom.parseAsRoot(["addon"]) is Addon.Status)
        #expect(try Darkbloom.parseAsRoot(["addon", "status"]) is Addon.Status)
        let hold = try #require(try Darkbloom.parseAsRoot(["addon", "hold", "--lease-seconds", "45"]) as? Addon.Hold)
        #expect(hold.leaseSeconds == 45)
        #expect(try Addon.Hold.parse([]).leaseSeconds == 600)
        #expect(throws: (any Error).self) { try Addon.Hold.parse(["--lease-seconds", "29"]) }
        #expect(throws: (any Error).self) { try Addon.Hold.parse(["--lease-seconds", "601"]) }
        #expect(try #require(try Darkbloom.parseAsRoot(["addon", "release", "--force"]) as? Addon.Release).force)
        #expect(try Addon.Release.parse([]).force == false)
    }

    @Test func requiresAFreshProviderThatServesAddons() throws {
        let identity = try #require(ProcessIdentity.current())
        let now = Date().timeIntervalSince1970
        var state = DaemonState(pid: identity.pid, processIdentity: identity, version: "x", writtenAt: now,
                                startedAt: now, addonHold: AddonHoldSnapshot(holds: []))
        #expect(try Addon.liveIdentity(state, now: now, isCurrent: { _ in true }) == identity)
        #expect(throws: ValidationError.self) { try Addon.liveIdentity(nil, now: now) }
        #expect(throws: ValidationError.self) { try Addon.liveIdentity(state, now: now + 600, isCurrent: { _ in true }) }
        #expect(throws: ValidationError.self) { try Addon.liveIdentity(state, now: now, isCurrent: { _ in false }) }
        state.addonHold = nil
        #expect(throws: ValidationError.self) { try Addon.liveIdentity(state, now: now, isCurrent: { _ in true }) }
    }

    @Test func rendersHoldsTheLockAndTheStatusLine() {
        let now = Date(timeIntervalSince1970: 1_800_000_030)
        let held = Addon.lines(.init(requestID: "r", holds: [Self.hold], machineLockHeld: true), now: now)
        #expect(held.first == "Add-on holds:")
        #expect(held[1].contains("io.darkbloom.sandbox: held since") && held[1].contains("lease expires in 30s"))
        #expect(held.last == "Machine lock: held (add-on VMs may be running)")
        let none = Addon.lines(.init(requestID: "r", holds: [], machineLockHeld: false), now: now)
        #expect(none == ["Add-on holds: none; the provider serves normally.", "Machine lock: free"])
        let expired = Addon.describe(Self.hold, now: Date(timeIntervalSince1970: 1_800_000_090))
        #expect(expired.contains("lease expired (kept while the machine lock is held)"))

        #expect(Status.addonHoldLine(nil) == nil)
        #expect(Status.addonHoldLine(AddonHoldSnapshot(holds: [])) == nil)
        let line = try? #require(Status.addonHoldLine(AddonHoldSnapshot(holds: [Self.hold, Self.hold]), now: now))
        #expect(line?.hasPrefix("Not serving: held by add-on io.darkbloom.sandbox") == true)
        #expect(line?.contains("(+1 more)") == true)
    }

    @Test func daemonStateRoundTripsTheHoldSnapshot() throws {
        let identity = try #require(ProcessIdentity.current())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("addon-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("daemon-state.json")
        let state = DaemonState(pid: identity.pid, processIdentity: identity, version: "x", writtenAt: 1,
                                startedAt: 1, addonHold: AddonHoldSnapshot(holds: [Self.hold]))
        DaemonStateFile.write(state, to: url)
        #expect(DaemonStateFile.read(from: url)?.addonHold == state.addonHold)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let snapshot = try #require(json["addon_hold"] as? [String: Any])
        let first = try #require((snapshot["holds"] as? [[String: Any]])?.first)
        #expect(first["hold_id"] as? String == "h" && first["lease_expires_at_ms"] as? Int == 1_800_000_060_000)
    }
}
