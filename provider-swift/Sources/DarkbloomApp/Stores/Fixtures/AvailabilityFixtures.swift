import Foundation

struct AvailabilityFixtureState: Equatable, Sendable {
    var loadState: AvailabilityStoreLoadState
    var policy: AvailabilityPolicy?
    var draft: AvailabilityPolicy?
    var runtime: AvailabilityRuntimeSnapshot?
    var saveShouldFail: Bool
    var initialSaveState: AvailabilitySaveAndRestartState
}

enum AvailabilityFixtures {
    /// Friday at 10:20 PM local time, inside the weeknight window.
    static let referenceDate = Date(timeIntervalSince1970: 1_784_352_000)
    /// Saturday at 7:20 AM local time, after the weeknight window and before
    /// the 9:00 AM weekend window.
    static let scheduledOffReferenceDate = Date(timeIntervalSince1970: 1_784_384_400)
    static let staleSourceDate = referenceDate.addingTimeInterval(-240)
    static let previewTimeZone = AvailabilityLocalTimeZone(
        identifier: "America/Los_Angeles",
        abbreviation: "PDT"
    )

    static func make(_ fixture: AvailabilityFixture) -> AvailabilityFixtureState {
        switch fixture {
        case .always:
            return ready(policy: alwaysPolicy, runtime: runtime(.available))

        case .scheduledActive:
            return ready(
                policy: scheduledPolicy,
                runtime: runtime(
                    .available,
                    nextChangeAt: referenceDate.addingTimeInterval(31_200)
                )
            )

        case .scheduledOff:
            return ready(
                policy: scheduledPolicy,
                runtime: runtime(
                    .scheduledOff,
                    sampledAt: scheduledOffReferenceDate,
                    nextChangeAt: scheduledOffReferenceDate.addingTimeInterval(6_000),
                    endpointReachable: nil
                )
            )

        case .pausedScheduled:
            return ready(
                policy: scheduledPolicy,
                runtime: runtime(.paused, endpointReachable: nil)
            )

        case .serving:
            return ready(policy: alwaysPolicy, runtime: runtime(.serving))

        case .loading:
            return AvailabilityFixtureState(
                loadState: .loading,
                policy: nil,
                draft: nil,
                runtime: nil,
                saveShouldFail: false,
                initialSaveState: .idle
            )

        case .stale:
            return AvailabilityFixtureState(
                loadState: .stale(
                    lastUpdated: staleSourceDate,
                    message: "Showing the last local provider configuration and runtime observation."
                ),
                policy: scheduledPolicy,
                draft: scheduledPolicy,
                runtime: AvailabilityRuntimeSnapshot(
                    sampledAt: referenceDate,
                    sourceUpdatedAt: staleSourceDate,
                    state: .stale,
                    unifiedLocalEndpointIsReachable: false
                ),
                saveShouldFail: false,
                initialSaveState: .idle
            )

        case .malformed:
            let issues = malformedIssues
            return AvailabilityFixtureState(
                loadState: .malformed(
                    message: "The saved availability schedule needs repair before it can be shown or changed.",
                    issues: issues
                ),
                policy: nil,
                draft: nil,
                runtime: runtime(.attention),
                saveShouldFail: false,
                initialSaveState: .idle
            )

        case .saveFailure:
            var editedPolicy = scheduledPolicy
            editedPolicy.idleUnloadMinutes = 15
            return ready(
                policy: scheduledPolicy,
                draft: editedPolicy,
                runtime: runtime(.available),
                saveShouldFail: true,
                initialSaveState: .failed(
                    message: "Darkbloom could not save the provider configuration. Your changes are still here."
                )
            )
        }
    }

    static var alwaysPolicy: AvailabilityPolicy {
        AvailabilityPolicy(
            mode: .wheneverRunning,
            localTimeZone: previewTimeZone,
            idleUnloadMinutes: AvailabilityPolicy.defaultIdleUnloadMinutes
        )
    }

    static var scheduledPolicy: AvailabilityPolicy {
        AvailabilityPolicy(
            mode: .scheduled,
            windows: [
                AvailabilityWindow(
                    id: "weeknights",
                    days: [.monday, .tuesday, .wednesday, .thursday, .friday],
                    start: time(20, 0),
                    end: time(7, 0)
                ),
                AvailabilityWindow(
                    id: "weekends",
                    days: [.saturday, .sunday],
                    start: time(9, 0),
                    end: time(18, 0)
                ),
            ],
            localTimeZone: previewTimeZone,
            idleUnloadMinutes: AvailabilityPolicy.defaultIdleUnloadMinutes
        )
    }

    private static var malformedIssues: [AvailabilityPolicySourceIssue] {
        let resolution = AvailabilityPolicyResolver.resolve(
            schedule: AvailabilityScheduleRecord(
                enabled: true,
                windows: [
                    AvailabilityScheduleWindowRecord(
                        days: ["mon"],
                        start: "20:00",
                        end: "20:00"
                    ),
                ]
            ),
            localTimeZone: previewTimeZone
        )
        guard case .malformed(let issues) = resolution else {
            preconditionFailure("Malformed fixture must never resolve as an always-available policy")
        }
        return issues
    }

    private static func ready(
        policy: AvailabilityPolicy,
        draft: AvailabilityPolicy? = nil,
        runtime: AvailabilityRuntimeSnapshot,
        saveShouldFail: Bool = false,
        initialSaveState: AvailabilitySaveAndRestartState = .idle
    ) -> AvailabilityFixtureState {
        AvailabilityFixtureState(
            loadState: .ready(lastUpdated: referenceDate),
            policy: policy,
            draft: draft ?? policy,
            runtime: runtime,
            saveShouldFail: saveShouldFail,
            initialSaveState: initialSaveState
        )
    }

    private static func runtime(
        _ state: AvailabilityRuntimeState,
        sampledAt: Date = referenceDate,
        nextChangeAt: Date? = nil,
        endpointReachable: Bool? = true
    ) -> AvailabilityRuntimeSnapshot {
        AvailabilityRuntimeSnapshot(
            sampledAt: sampledAt,
            sourceUpdatedAt: sampledAt,
            state: state,
            nextObservedTransitionAt: nextChangeAt,
            unifiedLocalEndpointIsReachable: endpointReachable
        )
    }

    private static func time(_ hour: Int, _ minute: Int) -> AvailabilityTimeOfDay {
        guard let time = AvailabilityTimeOfDay(hour: hour, minute: minute) else {
            preconditionFailure("Fixture time must be valid")
        }
        return time
    }
}
