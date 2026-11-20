import Foundation
import os

private let bootSecurityLogger = Logger(subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "security")

extension ProviderLoop {
    /// How often the hold looks for a stop, update or other service change.
    internal static let bootSecurityHoldPollInterval: Duration = .seconds(2)

    /// Darkbloom serving needs Apple's default boot security (see
    /// `BootSecuritySnapshot.servingRefusals`). Without it this process stays
    /// up with no coordinator connection until a stop, update or other service
    /// change begins, keeping the daemon-state stamp fresh: an exit would read
    /// to the crash-recovery watchdog as a crash loop and roll the update back.
    /// App Nap stays off so the stamp keeps its schedule; idle sleep is allowed.
    /// `afterServing`: the hold of a refusal found before a connection, after
    /// serving ended as at a stop (its refusals were logged then). It ends
    /// when a stop or update (a lifecycle drain) has drained, or on
    /// cancellation: a stop whose drain timed out leaves it holding for the
    /// next try, and drains serving had begun don't end it.
    internal func holdWithoutDarkbloomServing(_ refusals: [BootSecurityIssue], afterServing: Bool = false) async {
        if !afterServing { logServingOff(refusals) }
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Darkbloom provider waiting: boot security keeps serving off")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        bootSecurityHoldActive = true
        bootSecurityHoldKinds = refusals.map(\.kind.rawValue)
        defer {
            bootSecurityHoldActive = false
            bootSecurityHoldKinds = nil
        }
        // A drain that serving had begun (an update, a reconnect, a model switch) won't finish: the state doesn't
        // report it while the service holds. A stop's own status stays.
        if afterServing, servingDrain.owner != .lifecycle { lifecycleStatus = .init() }
        writeDaemonState()
        let liveness = startPreloadLivenessRefresh()
        defer { liveness.cancel() }
        if afterServing {
            refusalLiveness?.cancel()
            refusalLiveness = nil
        }
        func goesOn() -> Bool {
            afterServing ? !(servingDrain.owner == .lifecycle && servingDrain.phase == .drained)
                : !isShuttingDown && !servingDrain.refusingForServiceChange
        }
        while !Task.isCancelled, goesOn() {
            try? await taskSleep(Self.bootSecurityHoldPollInterval)
        }
    }

    /// The moment a refusal is found before a connection: local admission and the quote mirror close for good (no
    /// drain's resume reopens them; `throwIfRefusingNewLocalWork` refuses too), without taking a drain's owner, and
    /// the daemon-state stamp gets its own refresh. Nothing new starts while the event reader winds down and serving ends, work
    /// already accepted finishes within the shutdown's wait, and the crash-recovery watchdog sees a live process
    /// throughout.
    private func closeAdmissionForRefusal() {
        localResponseTracker.closeForGood()
        state.refuseNewWorkForGood()
        wakeClusterPairLocalWaiters()
        if refusalLiveness == nil { refusalLiveness = startPreloadLivenessRefresh() }
    }

    /// Whether the native owners are retired (`drainNativeMiMoOwners`), as serving's teardown and the end of a
    /// refusal's hold ask. Debug builds answer with a test's stand-in when one is set.
    internal func nativeOwnersRetired() async -> Bool {
        #if DEBUG
        if let standIn = nativeOwnersRetiredForTesting { return await standIn() }
        #endif
        return await drainNativeMiMoOwners()
    }

    /// After serving ended for a refusal found before a connection (`run()`, which has also released what only
    /// serving needed): the App Attest worker is stopped and joined, and the service holds until a stop or update
    /// has drained, or the caller cancels. A stop's drain still running then publishes its outcome before this
    /// returns.
    internal func holdAfterRefusal(_ refusals: [BootSecurityIssue]) async {
        if !Task.isCancelled {
            // A worker that didn't stop is stopped again by the stop that ends the hold; that stop drains only then.
            _ = await stopAppAttestWorkerAndWait()
            await holdWithoutDarkbloomServing(refusals, afterServing: true)
        }
        if let drain = lifecycleDrainTask { _ = await drain.value }
    }

    /// Asked by the coordinator client before each connection attempt, the
    /// first included, when startup couldn't read Secure Boot on a Mac that
    /// serves alone: the privacy capabilities that connection registers with
    /// (nil without a startup posture: the client keeps its own). While the
    /// policy is unread it is read once more (off this actor), so a
    /// registration never reports `unknown` from the startup reading alone. A
    /// policy once read is kept: it changes only in recoveryOS, with a restart.
    /// A refusal (a downgrade that read found) is published like the startup
    /// hold's (`bootSecurityHoldKinds`), kept in `refusalsBeforeConnecting`
    /// and thrown as `RegistrationRefused`: no connection registers, the client
    /// ends, serving ends as at a stop (`run()`), and the service then holds.
    internal func privacyCapabilitiesBeforeConnecting() async throws -> PrivacyCapabilities? {
        guard securityPosture != nil else { return nil }
        if securityPosture?.bootSecurity.secureBoot == .unknown, let read = secureBootRereader() {
            let reading = await Self.readOffLoop(read)
            // Applied to the posture as it is now, and only while it is still
            // unread: a policy read meanwhile, or a refusal, stays.
            if let current = securityPosture, current.bootSecurity.secureBoot == .unknown {
                let reread = current.rereadingSecureBoot(reading)
                securityPosture = reread
                logSecureBootReading(reading.counting(reread.bootSecurity.secureBootReadAttempts), when: "before connecting")
            }
        }
        let refusals = Self.bootSecurityHold(securityPosture)
        guard refusals.isEmpty else {
            let kinds = refusals.map(\.kind.rawValue)
            if bootSecurityHoldKinds != kinds {
                logServingOff(refusals)
                bootSecurityHoldKinds = kinds
            }
            refusalsBeforeConnecting = refusals
            closeAdmissionForRefusal()
            writeDaemonState()
            throw RegistrationRefused(reason: "boot settings keep Darkbloom serving off (\(kinds.joined(separator: ", ")))")
        }
        return Self.registrationPrivacyCapabilities(securityPosture)
    }

    private func logServingOff(_ refusals: [BootSecurityIssue]) {
        for refusal in refusals {
            bootSecurityLogger.error(
                "Darkbloom serving is off on this Mac. \(refusal.name, privacy: .public): \(refusal.detail, privacy: .public). Fix: \(refusal.fix, privacy: .public)"
            )
        }
    }

    /// Whether startup should stop reading Secure Boot again: a stop, an update
    /// or another service change began (`holdWithoutDarkbloomServing` waits for
    /// the same).
    internal func stopsStartupSecureBootReads() -> Bool {
        Task.isCancelled || isShuttingDown || servingDrain.refusingForServiceChange
    }

    /// The read before a connection while Secure Boot is unread: `system_profiler`,
    /// bounded in time and output, in release builds. Debug builds read only a
    /// test's stand-in commands (`setBootSettingsReadingForTesting`), never their
    /// host; the closure captures only that runner, which the test owns.
    private func secureBootRereader() -> (@Sendable () -> SecureBootReading)? {
        #if DEBUG
        guard let commands = bootSettingsReadingOverride?.commands else { return nil }
        return { SecureBootPolicy.read(runner: commands) }
        #else
        return { SecureBootPolicy.read() }
        #endif
    }

    /// Runs a blocking read on its own queue, so this actor isn't held while
    /// `system_profiler` answers.
    private static func readOffLoop(_ read: @escaping @Sendable () -> SecureBootReading) async -> SecureBootReading {
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "dev.darkbloom.secure-boot-read").async { continuation.resume(returning: read()) }
        }
    }
}
