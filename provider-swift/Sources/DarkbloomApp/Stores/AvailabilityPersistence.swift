import Foundation
import ProviderCoreFoundation

/// Pure policy decoding and one bounded read for partial-write recovery.
/// Config mutation and its atomicity remain owned by the existing CLI.
enum AvailabilityPersistence {
    static func resolve(_ payload: AvailabilityCLISchedule) -> AvailabilityPolicyResolution {
        AvailabilityPolicyResolver.resolve(
            schedule: AvailabilityScheduleRecord(
                enabled: payload.enabled,
                windows: payload.windows.map {
                    AvailabilityScheduleWindowRecord(days: $0.days, start: $0.start, end: $0.end)
                }
            ),
            localTimeZone: .current,
            idleUnloadMinutes: payload.idleTimeoutMinutes ?? AvailabilityPolicy.defaultIdleUnloadMinutes
        )
    }

    static func sameConfiguration(_ lhs: AvailabilityPolicy, _ rhs: AvailabilityPolicy) -> Bool {
        AvailabilityScheduleCLIArguments.scheduleArguments(for: lhs)
            == AvailabilityScheduleCLIArguments.scheduleArguments(for: rhs)
            && lhs.idleUnloadMinutes == rhs.idleUnloadMinutes
    }

    static func reconcile(using cli: any AvailabilityCLIRunning) async throws -> AvailabilityPolicy {
        let payload = try await cli.fetchSchedule()
        // The optional field supports older CLIs on initial load, but a
        // default cannot establish whether a failed idle write persisted.
        guard payload.idleTimeoutMinutes != nil else {
            throw AvailabilityCLIError.invalidOutput("idle timeout was not reported")
        }
        guard case .policy(let policy) = resolve(payload), policy.validation.isValid else {
            throw AvailabilityCLIError.invalidOutput("saved availability is malformed")
        }
        return policy
    }
}

/// Config is parsed at provider launch. The full policy (including idle timeout)
/// must be read back unchanged, and a fresh, kernel-verified process must have
/// started AFTER that policy was confirmed. The daemon additionally reports the
/// matching schedule. Its state does not report the loaded idle timeout, so an
/// old process or a config change first observed after launch cannot prove it.
struct AvailabilityRestartCheckpoint {
    let policy: AvailabilityPolicy
    let verifiedAt: Date

    func confirmsRestart(
        state: DaemonState,
        now: Date,
        readIdentity: (Int32) -> ProcessIdentity?
    ) -> Bool {
        let nowEpoch = now.timeIntervalSince1970
        let verifiedEpoch = verifiedAt.timeIntervalSince1970
        guard state.schema == DaemonState.currentSchema,
              state.writtenAt.isFinite, state.startedAt.isFinite,
              state.writtenAt <= nowEpoch,
              state.startedAt > verifiedEpoch,
              state.startedAt <= state.writtenAt,
              let identity = state.processIdentity,
              Double(identity.startTimeMicros) / 1_000_000 > verifiedEpoch,
              Double(identity.startTimeMicros) / 1_000_000 <= state.startedAt,
              DaemonStateRuntimeTruth.isFreshAndLive(
                state, now: nowEpoch, readIdentity: readIdentity),
              let schedule = state.schedule else { return false }

        switch policy.mode {
        case .wheneverRunning:
            return schedule.mode == "always" && schedule.summary == "always available"
                && schedule.nextChangeAtEpoch == nil
        case .scheduled:
            guard schedule.mode == "scheduled-active" || schedule.mode == "scheduled-off",
                  let nextChange = schedule.nextChangeAtEpoch,
                  nextChange.isFinite, nextChange > nowEpoch else { return false }
            // Schedule.describe preserves CLI day order; the editor stores a
            // set. An idle-only save must accept either order of the same days.
            let windows = schedule.summary.components(separatedBy: " | ")
            guard windows.count == policy.windows.count else { return false }
            return zip(windows, policy.windows).allSatisfy { summary, window in
                let parts = summary.split(separator: " ", maxSplits: 1)
                guard parts.count == 2,
                      parts[1] == "\(window.start.configurationValue)-\(window.end.configurationValue)" else { return false }
                let rawDays = parts[0].split(separator: ",", omittingEmptySubsequences: false)
                let days = rawDays.compactMap { AvailabilityWeekday.parse(String($0)) }
                return days.count == rawDays.count && Set(days) == window.days
            }
        }
    }
}
