import Foundation
import Testing

@testable import DarkbloomHardwareLoad

struct ProviderGPUShareTests {
    @Test func firstScanOnlySetsTheBaseline() {
        var share = ProviderGPUShare()
        #expect(share.update(clients: [GPUClientTime(entryID: 1, pid: 7, nanoseconds: 5)], providerPID: 7) == nil)
    }

    @Test func shareIsProviderTimeOverAllClientTime() {
        var share = ProviderGPUShare()
        _ = share.update(
            clients: [
                GPUClientTime(entryID: 1, pid: 7, nanoseconds: 100),
                GPUClientTime(entryID: 2, pid: 9, nanoseconds: 100),
            ], providerPID: 7)
        let value = share.update(
            clients: [
                GPUClientTime(entryID: 1, pid: 7, nanoseconds: 400),
                GPUClientTime(entryID: 2, pid: 9, nanoseconds: 200),
            ], providerPID: 7)
        #expect(value == 0.75)
    }

    @Test func closedAndNewConnectionsNeverGoBackwards() {
        var share = ProviderGPUShare()
        _ = share.update(
            clients: [
                GPUClientTime(entryID: 1, pid: 7, nanoseconds: 1_000),
                GPUClientTime(entryID: 2, pid: 9, nanoseconds: 500),
            ], providerPID: 7)
        // Entry 1 closed; entry 3 opened after the previous scan.
        let value = share.update(
            clients: [
                GPUClientTime(entryID: 2, pid: 9, nanoseconds: 600),
                GPUClientTime(entryID: 3, pid: 7, nanoseconds: 300),
            ], providerPID: 7)
        #expect(value == 0.75)
    }

    @Test func stoppedProviderAndIdleGPUReadZero() {
        var share = ProviderGPUShare()
        let clients = [GPUClientTime(entryID: 1, pid: 9, nanoseconds: 10)]
        _ = share.update(clients: clients, providerPID: nil)
        #expect(share.update(clients: [GPUClientTime(entryID: 1, pid: 9, nanoseconds: 90)], providerPID: nil) == 0)
        #expect(share.update(clients: [GPUClientTime(entryID: 1, pid: 9, nanoseconds: 90)], providerPID: 9) == 0)
    }

    @Test func parsesCreatorPIDWithoutReadingTheName() {
        #expect(GPUClientScanner.creatorPID("pid 4242, darkbloom") == 4242)
        #expect(GPUClientScanner.creatorPID("pid x, darkbloom") == nil)
        #expect(GPUClientScanner.creatorPID("kernel") == nil)
    }

    @Test func sumsAppUsageAcrossAPIs() {
        let usage: [[String: Any]] = [
            ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 1_500)],
            ["API": "GL", "accumulatedGPUTime": NSNumber(value: 500)],
            ["API": "Other"],
        ]
        #expect(GPUClientScanner.accumulatedNanoseconds(usage) == 2_000)
        #expect(GPUClientScanner.accumulatedNanoseconds("nope") == nil)
    }
}
