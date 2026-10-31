import Foundation
import IOKit.pwr_mgt
import Testing
@testable import ProviderCore

@Suite(.serialized) struct ClusterServicePowerAssertionTests {
    @Test func failedAcquisitionsRetryWithoutDuplicatingSuccessfulAssertions() {
        var sleepAttempts = 0
        var backgroundAttempts = 0
        var networkAttempts = 0
        var released: [UInt32] = []
        let inference = InferencePowerAssertion(reason: "retry test", createAssertion: { _ in
            sleepAttempts += 1
            return sleepAttempts == 1 ? nil : 1
        }, destroyAssertion: { released.append($0) })
        let network = NetworkPowerAssertion(reason: "retry test", createAssertion: { type, _ in
            if type == "NetworkClientActive" { networkAttempts += 1; return 2 }
            backgroundAttempts += 1
            return backgroundAttempts == 1 ? nil : 3
        }, destroyAssertion: { released.append($0) })
        let power = ClusterServicePowerAssertions(inference: inference, network: network)
        power.update(savedServing: true, partRunning: false, relayRunning: false)
        #expect(sleepAttempts == 1 && backgroundAttempts == 1 && networkAttempts == 1)
        power.update(savedServing: nil, partRunning: false, relayRunning: false)
        #expect(sleepAttempts == 2 && backgroundAttempts == 2 && networkAttempts == 1)
        for _ in 0..<100 { power.update(savedServing: true, partRunning: false, relayRunning: false) }
        #expect(sleepAttempts == 2 && backgroundAttempts == 2 && networkAttempts == 1)
        power.release()
        power.release()
        #expect(released.sorted() == [1, 2, 3])
    }

    @Test func inferenceOwnersRemainBalancedAcrossFailedAcquisition() {
        var attempts = 0
        var released: [UInt32] = []
        let inference = InferencePowerAssertion(reason: "owners test", createAssertion: { _ in
            attempts += 1
            return attempts == 1 ? nil : 4
        }, destroyAssertion: { released.append($0) })
        inference.acquire()
        inference.acquire()
        #expect(attempts == 2)
        inference.release()
        #expect(inference.ensureAcquired() && released.isEmpty)
        inference.release()
        #expect(!inference.ensureAcquired() && released == [4])
    }

    private func names(for reason: String) throws -> [String] {
        var assertions: Unmanaged<CFDictionary>?
        #expect(IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess)
        let values = try #require(assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]])
        return (values[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []).compactMap {
            guard $0[kIOPMAssertionNameKey] as? String == reason else { return nil }
            return $0[kIOPMAssertionTypeKey] as? String
        }.sorted()
    }

    @Test func savedDeploymentSurvivesIdleAndUnreadableSetup() throws {
        let reason = "Cluster power test " + UUID().uuidString
        let power = ClusterServicePowerAssertions(reason: reason)
        defer { power.release() }
        #expect(try names(for: reason).isEmpty)
        power.update(savedServing: true, partRunning: false, relayRunning: false)
        let acquired = try names(for: reason)
        #expect(acquired.contains(kIOPMAssertionTypeNoIdleSleep))
        #expect(acquired.contains("NetworkClientActive"))
        for _ in 0..<100 {
            power.update(savedServing: nil, partRunning: false, relayRunning: false)
        }
        #expect(try names(for: reason) == acquired)
        power.update(savedServing: false, partRunning: false, relayRunning: false)
        #expect(try names(for: reason).isEmpty)
    }

    @Test func teardownWaitsForChildAndRelayBeforeReleasing() throws {
        let reason = "Cluster teardown test " + UUID().uuidString
        let power = ClusterServicePowerAssertions(reason: reason)
        defer { power.release() }
        power.update(savedServing: true, partRunning: true, relayRunning: true)
        let acquired = try names(for: reason)
        #expect(!acquired.isEmpty)
        power.update(savedServing: false, partRunning: true, relayRunning: false)
        #expect(try names(for: reason) == acquired)
        power.update(savedServing: false, partRunning: false, relayRunning: true)
        #expect(try names(for: reason) == acquired)
        power.update(savedServing: false, partRunning: false, relayRunning: false)
        #expect(try names(for: reason).isEmpty)
    }

    @Test func serviceExitReleasesAndNewUnknownSetupDoesNotAcquire() throws {
        let reason = "Cluster exit test " + UUID().uuidString
        var power: ClusterServicePowerAssertions? = .init(reason: reason)
        power?.update(savedServing: nil, partRunning: false, relayRunning: false)
        #expect(try names(for: reason).isEmpty)
        power?.update(savedServing: false, partRunning: true, relayRunning: false)
        #expect(try names(for: reason).contains(kIOPMAssertionTypeNoIdleSleep))
        power = nil
        #expect(try names(for: reason).isEmpty)
    }
}
