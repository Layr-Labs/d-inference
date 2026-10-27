import Foundation
import Testing

@testable import ProviderCore

@Suite("Add-on IPC hold.v1 contract")
struct AddonIPCTests {
    private func parse(_ json: String) -> Result<AddonIPC.Request, AddonIPC.ErrorCode> {
        AddonIPC.parse(Data(json.utf8))
    }

    private func object(_ response: AddonIPC.Response) throws -> [String: Any] {
        let line = AddonIPC.encode(response)
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        return try #require(JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
    }

    @Test func everyOperationParses() {
        #expect(parse(#"{"v":1,"op":"hello"}"#) == .success(.hello))
        #expect(parse(#"{"v":1,"op":"hold","addon":"io.darkbloom.sandbox","vm_bytes":17179869184,"lease_seconds":60}"#)
            == .success(.hold(addon: "io.darkbloom.sandbox", vmBytes: 17_179_869_184, leaseSeconds: 60)))
        #expect(parse(#"{"v":1,"op":"status","hold_id":"h"}"#) == .success(.status(holdID: "h")))
        #expect(parse(#"{"v":1,"op":"renew","hold_id":"h","lease_seconds":600}"#)
            == .success(.renew(holdID: "h", leaseSeconds: 600)))
        #expect(parse(#"{"v":1,"op":"release","hold_id":"h"}"#) == .success(.release(holdID: "h")))
        // Unknown keys are ignored for forward compatibility.
        #expect(parse(#"{"v":1,"op":"hello","client":"sandbox/1.2"}"#) == .success(.hello))
    }

    @Test func leaseBoundsAreInclusive() {
        let hold = { (lease: Int) in
            parse(#"{"v":1,"op":"hold","addon":"io.darkbloom.sandbox","vm_bytes":0,"lease_seconds":\#(lease)}"#)
        }
        #expect(hold(30) == .success(.hold(addon: "io.darkbloom.sandbox", vmBytes: 0, leaseSeconds: 30)))
        #expect(hold(600) == .success(.hold(addon: "io.darkbloom.sandbox", vmBytes: 0, leaseSeconds: 600)))
        #expect(hold(29) == .failure(.invalidRequest))
        #expect(hold(601) == .failure(.invalidRequest))
        #expect(parse(#"{"v":1,"op":"renew","hold_id":"h","lease_seconds":10}"#) == .failure(.invalidRequest))
        #expect(parse(#"{"v":1,"op":"renew","hold_id":"h"}"#) == .failure(.invalidRequest))
    }

    @Test func versionIsCheckedBeforeTheOperation() {
        #expect(parse(#"{"v":2,"op":"hello"}"#) == .failure(.unsupportedVersion))
        #expect(parse(#"{"v":2,"op":"future"}"#) == .failure(.unsupportedVersion))
        #expect(parse(#"{"op":"hello"}"#) == .failure(.invalidRequest))
        #expect(parse(#"{"v":"1","op":"hello"}"#) == .failure(.invalidRequest))
        #expect(parse(#"{"v":true,"op":"hello"}"#) == .failure(.invalidRequest))
    }

    @Test func malformedRequestsAreInvalid() {
        for json in [
            "", "not json", "[1]", "1", #"{"v":1}"#, #"{"v":1,"op":"stop"}"#,
            #"{"v":1,"op":"hold","vm_bytes":0,"lease_seconds":60}"#,
            #"{"v":1,"op":"hold","addon":"io.darkbloom.sandbox","lease_seconds":60}"#,
            #"{"v":1,"op":"hold","addon":"io.darkbloom.sandbox","vm_bytes":-1,"lease_seconds":60}"#,
            #"{"v":1,"op":"hold","addon":"","vm_bytes":0,"lease_seconds":60}"#,
            #"{"v":1,"op":"hold","addon":"bad id/..","vm_bytes":0,"lease_seconds":60}"#,
            #"{"v":1,"op":"status"}"#, #"{"v":1,"op":"status","hold_id":""}"#,
            #"{"v":1,"op":"release","hold_id":7}"#,
        ] {
            #expect(parse(json) == .failure(.invalidRequest), "\(json)")
        }
    }

    @Test func messagesOverEightKiBAreRefused() {
        let padding = String(repeating: "x", count: AddonIPC.maximumMessageBytes)
        #expect(parse(#"{"v":1,"op":"hello","pad":"\#(padding)"}"#) == .failure(.invalidRequest))
        let fits = String(repeating: "x", count: AddonIPC.maximumMessageBytes - 40)
        #expect(parse(#"{"v":1,"op":"hello","pad":"\#(fits)"}"#) == .success(.hello))
    }

    @Test func responsesCarryExactlyTheDocumentedKeys() throws {
        let hello = try object(.hello(providerVersion: "1.2.3"))
        #expect(Set(hello.keys) == ["v", "ok", "capabilities", "provider_version"])
        #expect(hello["v"] as? Int == 1 && hello["ok"] as? Bool == true)
        #expect(hello["capabilities"] as? [String] == ["hold.v1"])
        #expect(hello["provider_version"] as? String == "1.2.3")

        let hold = try object(.hold(holdID: "id", state: .draining, sinceMs: 5, leaseExpiresAtMs: 65_005))
        #expect(Set(hold.keys) == ["v", "ok", "hold_id", "state", "since_ms", "lease_expires_at_ms"])
        #expect(hold["state"] as? String == "draining" && hold["since_ms"] as? Int == 5)

        let status = try object(.status(state: .expired, sinceMs: 5, leaseExpiresAtMs: 7))
        #expect(Set(status.keys) == ["v", "ok", "state", "since_ms", "lease_expires_at_ms"])
        #expect(status["state"] as? String == "expired")

        let renewed = try object(.renewed(state: .held, leaseExpiresAtMs: 9))
        #expect(Set(renewed.keys) == ["v", "ok", "state", "lease_expires_at_ms"])

        let released = try object(.released)
        #expect(Set(released.keys) == ["v", "ok", "state"] && released["state"] as? String == "released")

        for code in [AddonIPC.ErrorCode.unauthorized, .unsupportedVersion, .invalidRequest, .notFound, .unavailable] {
            let failure = try object(.failure(code))
            #expect(Set(failure.keys) == ["v", "ok", "error"])
            #expect(failure["ok"] as? Bool == false && failure["error"] as? String == code.rawValue)
        }
    }
}

@Suite("Add-on hold drain ownership")
struct AddonHoldDrainOwnershipTests {
    @Test func updateAndReconnectCannotReplaceOrReopenAHold() {
        var drain = ProviderDrain()
        drain.begin(.addonHold)
        for owner in [ProviderDrain.Owner.update, .reconnect, .modelSwitch] {
            drain.begin(owner)
            #expect(drain.owner == .addonHold)
        }
        drain.resumeUpdate()
        drain.resumeReconnect()
        drain.resumeModelSwitch()
        #expect(drain.owner == .addonHold && drain.refusing)
        #expect(!drain.refusingForServiceChange)
        drain.resumeAddonHold()
        #expect(drain.owner == nil && !drain.refusing)
    }

    @Test func aHoldTakesOverUpdateAndReconnectDrains() {
        for previous in [ProviderDrain.Owner.update, .reconnect] {
            var drain = ProviderDrain()
            drain.begin(previous)
            #expect(drain.refusingForServiceChange)
            drain.begin(.addonHold)
            #expect(drain.owner == .addonHold)
            // The superseded owner's resume is a no-op.
            if previous == .update { drain.resumeUpdate() } else { drain.resumeReconnect() }
            #expect(drain.refusing)
        }
    }

    @Test func onlyAStopPreemptsAHoldAndAHoldNeverPreemptsASwitchOrStop() {
        var held = ProviderDrain()
        held.begin(.addonHold)
        held.begin(.lifecycle)
        #expect(held.owner == .lifecycle && held.refusingForServiceChange)
        held.resumeAddonHold()
        #expect(held.owner == .lifecycle && held.refusing)

        for owner in [ProviderDrain.Owner.modelSwitch, .lifecycle] {
            var drain = ProviderDrain()
            drain.begin(owner)
            drain.begin(.addonHold)
            #expect(drain.owner == owner)
        }
    }
}
