import Foundation
import ProviderCoreFoundation

/// Converts the serving supervisor's parsed schedule into the persisted daemon
/// posture consumed by the app, CLI, and watchdog-adjacent runtime readers.
///
/// Both the active `ProviderLoop` and the off-window supervisor call this exact
/// resolver, so a handoff cannot disagree about the current mode or boundary.
public enum DaemonSchedulePostureResolver {
    public static func resolve(
        schedule: Schedule?,
        at date: Date
    ) -> DaemonState.SchedulePosture {
        guard let schedule else {
            return DaemonState.SchedulePosture(
                mode: "always",
                summary: "always available"
            )
        }

        let writtenAt = date.timeIntervalSince1970
        if schedule.isActive(at: date) {
            return DaemonState.SchedulePosture(
                mode: "scheduled-active",
                summary: schedule.describe(),
                nextChangeAtEpoch: schedule.durationUntilInactive(from: date).map {
                    writtenAt + $0
                }
            )
        }
        return DaemonState.SchedulePosture(
            mode: "scheduled-off",
            summary: schedule.describe(),
            nextChangeAtEpoch: writtenAt + schedule.durationUntilNextActive(from: date)
        )
    }
}
