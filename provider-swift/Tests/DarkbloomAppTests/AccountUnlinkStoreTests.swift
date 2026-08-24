import Foundation
import Testing
@testable import DarkbloomApp

@Suite("Native account unlink control")
struct AccountUnlinkStoreTests {
    @Test("The store invokes shipped logout, shows progress, then refreshes")
    @MainActor
    func successfulUnlinkOrderingAndStates() async {
        let events = UnlinkEventLog()
        let cli = ControlledUnlinkCLI(events: events)
        let store = AccountUnlinkStore(cli: cli, timeout: .seconds(7)) {
            await events.append("refresh")
        }

        let unlink = Task { await store.unlinkThisMac() }
        #expect(await cli.waitUntilStarted())
        #expect(store.state == .unlinking)
        let call = await cli.call
        #expect(call?.arguments == ["logout"])
        #expect(call?.timeout == .seconds(7))

        await cli.succeed()
        await unlink.value

        #expect(store.state == .succeeded)
        #expect(await events.values == ["cli-start", "cli-success", "refresh"])
    }

    @Test("Revocation failure leaves app state untouched and exposes retry guidance")
    @MainActor
    func failedUnlinkDoesNotRefresh() async throws {
        let events = UnlinkEventLog()
        let cli = ControlledUnlinkCLI(events: events)
        let store = AccountUnlinkStore(cli: cli) {
            await events.append("refresh")
        }

        let unlink = Task { await store.unlinkThisMac() }
        #expect(await cli.waitUntilStarted())
        await cli.fail(ProviderCLIError.exited(
            1,
            message: "coordinator rejected provider unlink"
        ))
        await unlink.value

        guard case .failed(let message) = store.state else {
            Issue.record("A failed CLI unlink must remain visibly retryable")
            return
        }
        #expect(message.contains("did not clear its account session"))
        #expect(message.contains("preserved this Mac’s local credentials"))
        #expect(message.contains("coordinator rejected provider unlink"))
        #expect(await events.values == ["cli-start", "cli-failure"])
    }

    @Test("Repeated taps cannot launch overlapping logout transactions")
    @MainActor
    func duplicateRequestIsIgnoredWhileUnlinking() async {
        let events = UnlinkEventLog()
        let cli = ControlledUnlinkCLI(events: events)
        let store = AccountUnlinkStore(cli: cli) {}

        let first = Task { await store.unlinkThisMac() }
        #expect(await cli.waitUntilStarted())
        await store.unlinkThisMac()
        #expect(await cli.callCount == 1)

        await cli.succeed()
        await first.value
        #expect(store.state == .succeeded)
    }

    @Test("The native control maps every transaction state to honest UI")
    func controlPresentationStates() {
        let idle = AccountUnlinkControlPresentation(state: .idle)
        #expect(idle.status == .hidden)
        #expect(idle.actionTitle == "Sign Out & Unlink This Mac…")
        #expect(!idle.actionDisabled)

        let unlinking = AccountUnlinkControlPresentation(state: .unlinking)
        #expect(unlinking.status == .progress("Securely unlinking this Mac…"))
        #expect(unlinking.actionTitle == "Sign Out & Unlink This Mac…")
        #expect(unlinking.actionDisabled)

        let succeeded = AccountUnlinkControlPresentation(state: .succeeded)
        #expect(succeeded.status == .success(AccountUnlinkPresentation.successMessage))
        #expect(succeeded.actionTitle == nil)
        #expect(succeeded.actionDisabled)

        let failed = AccountUnlinkControlPresentation(
            state: .failed(message: "Revocation failed")
        )
        #expect(failed.status == .failure("Revocation failed"))
        #expect(failed.actionTitle == "Retry Sign Out & Unlink…")
        #expect(!failed.actionDisabled)
    }

    @Test("Copy distinguishes saved-record removal, current-Mac unlink, and history")
    func destructiveCopyIsExplicit() {
        #expect(AccountUnlinkPresentation.confirmationMessage.contains(
            "Unlike removing a saved My Macs record"
        ))
        #expect(AccountUnlinkPresentation.confirmationMessage.contains(
            "revokes this Mac’s provider token"
        ))
        #expect(AccountUnlinkPresentation.confirmationMessage.contains(
            "does not delete contribution history"
        ))

        #expect(MyMacRemovalPresentation.confirmationMessage.contains(
            "does not unlink a running Mac"
        ))
        #expect(MyMacRemovalPresentation.confirmationMessage.contains(
            "Contribution history remains"
        ))
        #expect(MyMacRemovalPresentation.actionTitle == "Remove Saved Record")
        #expect(MyMacRemovalPresentation.confirmationTitle(
            macTitle: "Studio"
        ) == "Remove Studio from My Macs?")
    }
}

private actor UnlinkEventLog {
    private var storage: [String] = []

    var values: [String] { storage }

    func append(_ event: String) {
        storage.append(event)
    }
}

private actor ControlledUnlinkCLI: ProviderCLIRunning {
    struct Call: Sendable {
        let arguments: [String]
        let timeout: Duration
    }

    private let events: UnlinkEventLog
    private var continuation:
        CheckedContinuation<ProviderCLIResult, any Error>?
    private(set) var call: Call?
    private(set) var callCount = 0

    init(events: UnlinkEventLog) {
        self.events = events
    }

    func run(
        arguments: [String],
        timeout: Duration
    ) async throws -> ProviderCLIResult {
        callCount += 1
        call = Call(arguments: arguments, timeout: timeout)
        await events.append("cli-start")
        do {
            let result = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<ProviderCLIResult, any Error>) in
                self.continuation = continuation
            }
            await events.append("cli-success")
            return result
        } catch {
            await events.append("cli-failure")
            throw error
        }
    }

    func succeed() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: ProviderCLIResult(
            exitStatus: 0,
            stderrTail: ""
        ))
    }

    func fail(_ error: ProviderCLIError) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }

    func waitUntilStarted() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline {
            if continuation != nil { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return continuation != nil
    }
}
