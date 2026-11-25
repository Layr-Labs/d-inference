import CryptoKit
import DarkbloomClusterSecurity
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

@Suite struct CollectiveScopeTests {
    @Test func immutableRequestPartAndSetupBindings() throws {
        let pair = try CollectiveScopePair(), request = try pair.request()
        let payload = try request.operation(.residualPayload, metadata: Data("frame-0".utf8))
        let length = try payload.part(.controlLength), body = try payload.part(.controlBody)
        #expect(length.context.expectationSHA256 != body.context.expectationSHA256)
        #expect(payload.context.expectationSHA256 != body.context.expectationSHA256)
        let another = try pair.request("a13e5d3f-d6b5-42e4-956c-a9289d7d3b96")
        #expect(try another.operation(.residualPayload, metadata: Data("frame-0".utf8)).context.requestID != payload.context.requestID)
        #expect(throws: ClusterRecordError.self) { try request.operation(.loadedReady, metadata: Data()) }
        #expect(throws: ClusterRecordError.self) { try CollectiveOperationScope.setup(.requestRetired, agreementSHA256: String(repeating: "11", count: 32)) }
        #expect(throws: ProbeError.self) { try request.operation(.residualHeader, metadata: Data(repeating: 0, count: 16_385)) }
        for hash in [String(repeating: "A", count: 64), String(repeating: "0", count: 63), ""] {
            #expect(throws: ProbeError.self) { try CollectiveRequestScope(requestID: UUID(), epoch: pair.binding.epoch,
                planSHA256: hash, agreementSHA256: String(repeating: "31", count: 32)) }
        }
        let changedEpoch = try ClusterRecordBinding(epoch: UUID(), planSHA256: pair.binding.planSHA256,
            membershipTranscriptSHA256: pair.binding.membershipTranscriptSHA256)
        #expect(throws: ProbeError.self) { try payload.requireBinding(changedEpoch) }
        let changedPlan = try ClusterRecordBinding(epoch: pair.binding.epoch, planSHA256: Data(repeating: 0x22, count: 32),
            membershipTranscriptSHA256: pair.binding.membershipTranscriptSHA256)
        #expect(throws: ProbeError.self) { try payload.requireBinding(changedPlan) }
    }

    @Test func setupRequestsRetirementShareDirectionalCounters() throws {
        let pair = try CollectiveScopePair(), firstRequest = try pair.request()
        let secondRequest = try pair.request("a13e5d3f-d6b5-42e4-956c-a9289d7d3b96")
        let scopes = try [
            CollectiveOperationScope.setup(.loadAgreement, agreementSHA256: String(repeating: "41", count: 32)),
            .setup(.loadedReady, agreementSHA256: String(repeating: "42", count: 32)),
            firstRequest.operation(.requestAgreement, metadata: Data()),
            firstRequest.operation(.residualPayload, metadata: Data([1])),
            firstRequest.operation(.requestRetired, metadata: Data([2])),
            secondRequest.operation(.requestAgreement, metadata: Data()),
            secondRequest.operation(.residualPayload, metadata: Data([1])),
        ]
        let bytes = Data(repeating: 7, count: 8)
        for (index, scope) in scopes.enumerated() {
            let expected = try pair.expectation(scope)
            try pair.first.send(bytes, expecting: expected, check: {})
            #expect(try pair.second.receive(expecting: expected, check: {}) == bytes)
            #expect(pair.first.status.codec.sealedRecords == UInt64(index + 1))
            #expect(pair.second.status.codec.openedRecords == UInt64(index + 1))
        }
        #expect(pair.frames.sentCounts[0] == Array(repeating: 48, count: scopes.count))
        #expect(pair.frames.incoming.allSatisfy(\.isEmpty))
        let reverse = try pair.expectation(scopes[4])
        try pair.second.send(bytes, expecting: reverse, check: {})
        #expect(try pair.first.receive(expecting: reverse, check: {}) == bytes)
        #expect(pair.first.status.codec.openedRecords == 1)
        #expect(pair.first.status.codec.sealedRecords == 7)
    }

    @Test func wrongRequestPartAndRetirementCannotPublish() throws {
        for fault in 0..<3 {
            let pair = try CollectiveScopePair(), request = try pair.request()
            let send = try request.operation(.residualPayload, metadata: Data([0])).part(.controlBody)
            let receive: CollectiveOperationScope
            if fault == 0 {
                receive = try pair.request("a13e5d3f-d6b5-42e4-956c-a9289d7d3b96")
                    .operation(.residualPayload, metadata: Data([0])).part(.controlBody)
            } else if fault == 1 {
                receive = try request.operation(.residualPayload, metadata: Data([0])).part(.controlLength)
            } else { receive = try request.operation(.requestRetired, metadata: Data([0])).part(.controlBody) }
            try pair.first.send(Data(repeating: 7, count: 8), expecting: pair.expectation(send), check: {})
            var published = false
            #expect(throws: (any Error).self) {
                _ = try pair.second.receive(expecting: pair.expectation(receive), check: {}); published = true
            }
            #expect(!published && !pair.second.status.active)
            #expect(pair.second.status.codec.openedRecords == 0)
        }
    }

    @Test func replayAcrossNewScopeAndReentrantIOPoisonSharedCodec() throws {
        let pair = try CollectiveScopePair(), scope = try pair.request().operation(.residualPayload, metadata: Data([0]))
        let expected = try pair.expectation(scope), bytes = Data(repeating: 9, count: 8)
        try pair.first.send(bytes, expecting: expected, check: {})
        let prior = pair.frames.incoming[1][0]
        #expect(try pair.second.receive(expecting: expected, check: {}) == bytes)
        pair.frames.incoming[1].append(prior)
        #expect(throws: (any Error).self) { try pair.second.receive(expecting: expected, check: {}) }
        #expect(!pair.second.status.active && pair.second.status.codec.openedRecords == 1)
        let reentrant = try CollectiveScopePair(), reentrantExpected = try reentrant.expectation(scope)
        reentrant.firstIO.beforeSend = { try reentrant.first.send(bytes, expecting: reentrantExpected, check: {}) }
        defer { reentrant.firstIO.beforeSend = nil }
        #expect(throws: (any Error).self) { try reentrant.first.send(bytes, expecting: reentrantExpected, check: {}) }
        #expect(!reentrant.first.status.active && reentrant.frames.sentCounts[0].isEmpty)
    }

    @Test func cancelledReceiveCannotPublishOrReopen() throws {
        let pair = try CollectiveScopePair(), scope = try pair.request().operation(.targetToken, metadata: Data())
        let expected = try pair.expectation(scope)
        try pair.first.send(Data(repeating: 3, count: 8), expecting: expected, check: {})
        var published = false
        #expect(throws: ProbeError.self) {
            _ = try pair.second.receive(expecting: expected, check: { throw ProbeError("fixture cancellation") }); published = true
        }
        #expect(!published && !pair.second.status.active && pair.second.status.codec.openedRecords == 0)
        #expect(throws: (any Error).self) { try pair.second.receive(expecting: expected, check: {}) }
    }

    @Test func unqualifiedProtectionRefusesBeforeNativeConstruction() throws {
        let pair = try CollectiveScopePair()
        let configuration = CollectiveProtectionConfiguration(sessionKey: SymmetricKey(data: Data(repeating: 0, count: 32)),
            binding: pair.binding, limits: try .init(maximumPlaintextBytes: 1024), maximumFrameBytes: 1064,
            resourcePolicy: .unqualified)
        #expect(throws: ProbeError.self) { try Collective.protected(configuration: configuration) }
    }
}
