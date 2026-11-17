// Copyright © 2026 Eigen Labs.

import Foundation
import Testing
@testable import ProviderCore

extension NemotronSuperManagedSlotTests {
    /// A coordinator request, image or text, whose first content the owner's
    /// own measured pace cannot deliver before its forwarded deadline is
    /// refused at once as `deadline_unreachable`, the re-routable pre-content
    /// refusal, with nothing streamed and nothing left charged. The same request
    /// with no forwarded budget (a local or own-machine request) is served, as
    /// every request is with the switch off.
    @Test(.timeLimit(.minutes(3)), arguments: [true, false])
    func coordinatorRequestThePaceCannotStartInTimeIsRefusedAtOnce(refusalOn: Bool) async throws {
        let environment = refusalOn ? [:] : [NemotronSuperLocalBridgeBuilder.firstContentRefusalKey: "off"]
        let fixture = try await Self.fixture(mode: .off, environment: environment)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loop = fixture.loop, script = fixture.script
        try await loop.ensureModelLoaded(modelId: Self.modelID, allowEviction: false,
                                         revisionDirectory: fixture.directory)
        let slot = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        let owner = try #require(await slot.localOwnerForTesting())
        #expect(owner.refusesUnreachableFirstContent == refusalOn)
        // Two earlier requests ran alone and reached their deadlines with no
        // first chunk: 9,000 prompt tokens in 9,000 s, a second a token at least.
        let now = ContinuousClock.now
        for _ in 0 ..< 2 {
            #expect(owner.admitLocalRequest())
            let missed = NemotronSuperLocalBridgeBuilder.Owner.LocalRequestProgress(isMedia: true)
            owner.beginLocalRequest(missed, firstContentDeadline: now, now: now - .seconds(9_000))
            try owner.admitFirstContent(missed, promptTokens: 9_000, now: now - .seconds(9_000))
            owner.finishLocalRequest(missed, now: now)
        }
        #expect(owner.firstContentEvidence.misses.count == 2)
        let held = await fixture.budget.reservationBytesSnapshot()
        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        for (name, body) in [("image", try Self.imageBody(["Sunny."], script: script, maxTokens: 1)),
                             ("text", try Self.body(["Hi."], script: script))] {
            let start = ContinuousClock.now
            let forwarded = try await Self.send(body, to: loop, recorder: recorder, consumer: consumer,
                firstContentDeadline: FirstContentDeadline(relativeBudgetMilliseconds: 2_000))
            if refusalOn {
                let failure = try #require(Self.failure(forwarded.terminal), "\(name): \(forwarded.terminal)")
                #expect(failure.errorReason == .deadlineUnreachable, "\(name): \(forwarded.terminal)")
                #expect(forwarded.sse.isEmpty, "\(name)")
                // At once, not when the deadline passes.
                #expect(ContinuousClock.now - start < .seconds(2), "\(name)")
            } else {
                #expect(Self.usage(forwarded.terminal) != nil, "\(name): \(forwarded.terminal)")
            }
            script.set(["Ok."])
            let local = try await Self.send(body, to: loop, recorder: recorder, consumer: consumer)
            #expect(Self.usage(local.terminal) != nil, "\(name) without a budget: \(local.terminal)")
        }
        #expect(owner.firstContentEvidence.misses.count == 2)
        #expect(await fixture.budget.reservationBytesSnapshot() == held)
    }
}
