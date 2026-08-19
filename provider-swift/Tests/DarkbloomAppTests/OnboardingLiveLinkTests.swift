import Foundation
import Testing
@testable import DarkbloomApp

/// Onboarding's account step driving REAL `darkbloom login --json` attempts:
/// the fixture/simulated path stays for previews, live runs stream NDJSON
/// events and gate `accountPhase == .linked` on a terminal `.linked`.
@Suite("Onboarding live account linking")
@MainActor
struct OnboardingLiveLinkTests {

    /// Scripted `AccountLinkRunning`: each `linkEvents()` call replays the
    /// next queued attempt. `throwsAtEnd` models a transport failure (the
    /// stream fails instead of finishing), distinct from an in-band
    /// `.error` event.
    final class ScriptedRunner: AccountLinkRunning, @unchecked Sendable {
        struct Attempt: Sendable {
            var events: [AccountLinkEvent]
            var throwsAtEnd: Error?
            var openEnded: Bool

            init(events: [AccountLinkEvent], throwsAtEnd: Error? = nil, openEnded: Bool = false) {
                self.events = events
                self.throwsAtEnd = throwsAtEnd
                self.openEnded = openEnded
            }
        }

        private let lock = NSLock()
        private var scripts: [Attempt]
        private(set) var attempts = 0

        init(scripts: [Attempt]) {
            self.scripts = scripts
        }

        func linkEvents() -> AsyncThrowingStream<AccountLinkEvent, Error> {
            let attempt: Attempt? = lock.withLock {
                attempts += 1
                return scripts.isEmpty ? nil : scripts.removeFirst()
            }
            guard let attempt else {
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ProviderCLIError.cliNotFound)
                }
            }
            return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
                for event in attempt.events {
                    continuation.yield(event)
                }
                if attempt.openEnded {
                    // Never finishes and never yields again: simulates the
                    // user ignoring the browser tab forever. Cancellation is
                    // the only exit.
                    continuation.onTermination = { _ in }
                    return
                }
                if let error = attempt.throwsAtEnd {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    private func makeFlow(
        runner: ScriptedRunner,
        openedURLs: LockedURLs? = nil
    ) -> OnboardingFlowModel {
        let openedURLs = openedURLs ?? LockedURLs()
        return OnboardingFlowModel(
            startingAt: .account,
            accountLinkRunner: runner,
            verificationURLHandler: { openedURLs.append($0) }
        )
    }

    final class LockedURLs: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL] = []

        var urls: [URL] { lock.withLock { storage } }

        func append(_ url: URL) {
            lock.withLock { storage.append(url) }
        }
    }

    /// Poll the @MainActor flow state until the predicate holds (or 5 s).
    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @Test("Happy path: code event shows the real code, opens the URL, linked event completes the step")
    func liveLinkHappyPath() async throws {
        let opened = LockedURLs()
        let runner = ScriptedRunner(scripts: [
            .init(events: [
                .code(userCode: "REAL-C0DE", verificationURI: "https://app.darkbloom.dev/link", expiresIn: 600),
                .linked,
            ]),
        ])
        let flow = makeFlow(runner: runner, openedURLs: opened)
        #expect(flow.usesLiveAccountLink)
        #expect(!flow.canContinue)

        // Phase transitions arrive via the draft-change handler — polling the
        // phase directly would race: code→linked can land in one MainActor
        // turn, so a later poll only ever sees the terminal state.
        var observedPhases: [AccountLinkPhase] = []
        flow.setDraftChangeHandler { draft in
            if observedPhases.last != draft.accountPhase {
                observedPhases.append(draft.accountPhase)
            }
        }

        flow.startAccountLink()

        let linked = await eventually { flow.accountPhase == .linked }
        #expect(linked)
        #expect(flow.canContinue)
        #expect(!flow.accountLinkRequestInFlight)
        #expect(runner.attempts == 1)

        // The code phase preceded the terminal link, with the real code,
        // expiry, and a deeplinked URL.
        #expect(observedPhases == [.waitingForApproval, .linked])
        #expect(flow.accountLinkSession.code == "REAL-C0DE")
        #expect(flow.accountLinkSession.verificationURI == "https://app.darkbloom.dev/link")
        #expect(flow.accountLinkSession.lifetimeMinutes == 10)
        #expect(opened.urls == [URL(string: "https://app.darkbloom.dev/link")!])

        flow.continueToNextStep()
        #expect(flow.step == .enrollment)
    }

    @Test("Expiry event flips to .expired with the coordinator's message; retry runs a fresh attempt")
    func liveLinkExpiryThenRetry() async throws {
        let runner = ScriptedRunner(scripts: [
            .init(events: [
                .code(userCode: "STAL-ECDE", verificationURI: "https://app.darkbloom.dev/link", expiresIn: 600),
                .error(message: "Device code expired. Run 'darkbloom login' again."),
            ]),
            .init(events: [
                .code(userCode: "FRES-HCDE", verificationURI: "https://app.darkbloom.dev/link", expiresIn: 600),
                .linked,
            ]),
        ])
        let flow = makeFlow(runner: runner)

        flow.startAccountLink()
        let expired = await eventually { flow.accountPhase == .expired }
        #expect(expired)
        #expect(flow.accountLinkFailureDetail?.contains("expired") == true)
        #expect(!flow.canContinue)

        flow.startAccountLink()
        let linked = await eventually { flow.accountPhase == .linked }
        #expect(linked)
        #expect(flow.accountLinkSession.code == "FRES-HCDE")
        #expect(flow.accountLinkFailureDetail == nil)
        #expect(flow.canContinue)
        #expect(runner.attempts == 2)
    }

    @Test("Coordinator refusal / unreachable CLI surfaces as a retryable failure")
    func liveLinkFailures() async throws {
        let denying = ScriptedRunner(scripts: [
            .init(events: [
                .code(userCode: "DENI-ED00", verificationURI: "https://app.darkbloom.dev/link", expiresIn: 600),
                .error(message: "Authorization failed: user declined"),
            ]),
        ])
        let flow = makeFlow(runner: denying)
        flow.startAccountLink()
        let unreachable = await eventually { flow.accountPhase == .unreachable }
        #expect(unreachable)
        #expect(flow.accountLinkFailureDetail?.contains("user declined") == true)
        #expect(!flow.canContinue)

        // Transport failure (no events at all — e.g. CLI missing).
        let missing = ScriptedRunner(scripts: [])
        let deadFlow = makeFlow(runner: missing)
        deadFlow.startAccountLink()
        let failed = await eventually { deadFlow.accountPhase == .unreachable }
        #expect(failed)
        #expect(deadFlow.accountLinkFailureDetail != nil)
    }

    @Test("An already-linked machine maps the error message onto .linked")
    func liveLinkAlreadyLoggedIn() async {
        let runner = ScriptedRunner(scripts: [
            .init(events: [
                .error(message: "Already logged in (token: existing-token-1234...). Run 'darkbloom logout' first to unlink."),
            ]),
        ])
        let flow = makeFlow(runner: runner)
        flow.startAccountLink()
        let linked = await eventually { flow.accountPhase == .linked }
        #expect(linked)
        #expect(flow.canContinue)
        #expect(flow.accountLinkFailureDetail == nil)
    }

    @Test("Navigating away cancels the attempt and ignores late events")
    func liveLinkCancellation() async {
        let runner = ScriptedRunner(scripts: [
            .init(events: [
                .code(userCode: "HALF-WAY0", verificationURI: "https://app.darkbloom.dev/link", expiresIn: 600),
            ], openEnded: true),
        ])
        let flow = makeFlow(runner: runner)
        flow.startAccountLink()

        let waiting = await eventually { flow.accountPhase == .waitingForApproval }
        #expect(waiting)

        flow.cancelPendingOperations()
        let settled = await eventually { !flow.accountLinkRequestInFlight }
        #expect(settled)
        // The attempt was cut pre-approval: the phase must not advance to
        // .linked on its own (no lingering task can mutate the flow).
        try? await Task.sleep(for: .milliseconds(100))
        #expect(flow.accountPhase == .waitingForApproval)

        // Going back uses the same cancellation path (regression anchor).
        let flow2 = makeFlow(runner: runner)
        flow2.startAccountLink()
        _ = await eventually { flow2.accountPhase == .waitingForApproval }
        #expect(flow2.goBack())
        #expect(flow2.step == .readiness)
        let settled2 = await eventually { !flow2.accountLinkRequestInFlight }
        #expect(settled2)
    }

    @Test("Preview flows never touch the runner: startAccountLink keeps the fixture path")
    func frozenPreviewKeepsFixturePath() async {
        // No runner at all: a frozen flow must still preview approval.
        let flow = OnboardingFlowModel(
            startingAt: .account,
            previewVariant: nil,
            freezesAutomaticProgress: true,
            accountLinkRunner: nil
        )
        #expect(!flow.usesLiveAccountLink)

        flow.startAccountLink()
        #expect(flow.accountPhase == .waitingForApproval)
        #expect(flow.accountLinkSession.code == OnboardingAccountLinkSession.fixture(issuedAt: .now, attempt: 0).code)

        await flow.confirmAccountApproval()
        #expect(flow.accountPhase == .linked)
    }
}
