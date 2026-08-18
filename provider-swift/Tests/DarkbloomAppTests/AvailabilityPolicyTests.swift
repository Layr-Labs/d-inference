import Foundation
import Testing
@testable import DarkbloomApp

@Test("Missing and disabled schedules resolve to the documented whenever-running default")
func availabilityMissingScheduleUsesDefault() {
    let zone = AvailabilityLocalTimeZone(identifier: "America/Los_Angeles", abbreviation: "PDT")

    for schedule in [
        Optional<AvailabilityScheduleRecord>.none,
        AvailabilityScheduleRecord(enabled: false, windows: []),
    ] {
        let resolution = AvailabilityPolicyResolver.resolve(
            schedule: schedule,
            localTimeZone: zone
        )
        guard case .policy(let policy) = resolution else {
            Issue.record("A missing or disabled schedule should use the provider default")
            continue
        }
        #expect(policy.mode == .wheneverRunning)
        #expect(policy.windows.isEmpty)
        #expect(policy.localTimeZone == zone)
        #expect(policy.idleUnloadMinutes == 60)
    }
}

@Test("Enabled malformed schedules never silently become always available")
func availabilityMalformedScheduleStaysDistinct() {
    let resolution = AvailabilityPolicyResolver.resolve(
        schedule: AvailabilityScheduleRecord(
            enabled: true,
            windows: [
                AvailabilityScheduleWindowRecord(
                    days: ["not-a-day"],
                    start: "9am",
                    end: "17:00"
                ),
            ]
        )
    )

    guard case .malformed(let issues) = resolution else {
        Issue.record("Malformed enabled schedule must not resolve to a policy")
        return
    }
    #expect(issues.contains(.invalidDay(windowIndex: 0, value: "not-a-day")))
    #expect(issues.contains(.invalidStartTime(windowIndex: 0, value: "9am")))
}

@Test("Schedule day parsing matches the provider's accepted spellings")
func availabilityDayParsingMatchesProvider() {
    #expect(AvailabilityWeekday.parse("TUE") == .tuesday)
    #expect(AvailabilityWeekday.parse("Tuesday") == .tuesday)
    #expect(AvailabilityWeekday.parse("tues") == nil)
    #expect(AvailabilityWeekday.parse("thurs") == nil)
    #expect(AvailabilityWeekday.parse(" mon ") == nil)
    #expect(AvailabilityTimeOfDay.parseConfigurationValue("9:00")?.hour == 9)
}

@Test("Overnight windows wrap, while equal endpoints are rejected")
func availabilityOvernightSemanticsAndEqualEndpointValidation() throws {
    let overnight = AvailabilityWindow(
        id: "overnight",
        days: [.monday],
        start: try #require(AvailabilityTimeOfDay(hour: 22, minute: 0)),
        end: try #require(AvailabilityTimeOfDay(hour: 8, minute: 0))
    )
    #expect(overnight.isOvernight)

    let equal = AvailabilityWindow(
        id: "equal",
        days: [.monday],
        start: try #require(AvailabilityTimeOfDay(hour: 8, minute: 0)),
        end: try #require(AvailabilityTimeOfDay(hour: 8, minute: 0))
    )
    #expect(equal.isOvernight)

    let policy = AvailabilityPolicy(mode: .scheduled, windows: [equal])
    #expect(policy.validation.issues.contains(.windowHasEqualStartAndEnd(windowID: "equal")))
}

@Test("Weekly schedule validation rejects overlaps and touching boundaries")
func availabilityScheduleRejectsOverlapAndAdjacency() throws {
    let mondayOvernight = AvailabilityWindow(
        id: "monday-overnight",
        days: [.monday],
        start: try #require(AvailabilityTimeOfDay(hour: 22, minute: 0)),
        end: try #require(AvailabilityTimeOfDay(hour: 8, minute: 0))
    )
    let tuesdayTouching = AvailabilityWindow(
        id: "tuesday-touching",
        days: [.tuesday],
        start: try #require(AvailabilityTimeOfDay(hour: 8, minute: 0)),
        end: try #require(AvailabilityTimeOfDay(hour: 12, minute: 0))
    )
    let tuesdayOverlapping = AvailabilityWindow(
        id: "tuesday-overlap",
        days: [.tuesday],
        start: try #require(AvailabilityTimeOfDay(hour: 7, minute: 30)),
        end: try #require(AvailabilityTimeOfDay(hour: 9, minute: 0))
    )

    let touchingPolicy = AvailabilityPolicy(
        mode: .scheduled,
        windows: [mondayOvernight, tuesdayTouching]
    )
    #expect(touchingPolicy.validation.issues.contains(
        .windowsOverlapOrTouch(
            firstWindowID: "monday-overnight",
            secondWindowID: "tuesday-touching"
        )
    ))

    let overlappingPolicy = AvailabilityPolicy(
        mode: .scheduled,
        windows: [mondayOvernight, tuesdayOverlapping]
    )
    #expect(overlappingPolicy.validation.issues.contains(
        .windowsOverlapOrTouch(
            firstWindowID: "monday-overnight",
            secondWindowID: "tuesday-overlap"
        )
    ))
}

@Test("Weekly validation catches Sunday-to-Monday wraparound")
func availabilityScheduleChecksWeekBoundary() throws {
    let sunday = AvailabilityWindow(
        id: "sunday",
        days: [.sunday],
        start: try #require(AvailabilityTimeOfDay(hour: 22, minute: 0)),
        end: try #require(AvailabilityTimeOfDay(hour: 8, minute: 0))
    )
    let monday = AvailabilityWindow(
        id: "monday",
        days: [.monday],
        start: try #require(AvailabilityTimeOfDay(hour: 7, minute: 0)),
        end: try #require(AvailabilityTimeOfDay(hour: 9, minute: 0))
    )
    let policy = AvailabilityPolicy(mode: .scheduled, windows: [sunday, monday])

    #expect(policy.validation.issues.contains(
        .windowsOverlapOrTouch(firstWindowID: "sunday", secondWindowID: "monday")
    ))
}

@Test("Non-overlapping multi-window policy remains valid")
func availabilityValidMultipleWindows() {
    let policy = AvailabilityFixtures.scheduledPolicy
    #expect(policy.validation.isValid)
    #expect(policy.windows.count == 2)
    #expect(policy.localTimeZone.observesSystemChanges)
}

@Test("Planned schedule boundaries advance without a provider heartbeat")
func availabilityPlannedBoundariesComeFromLocalPolicy() throws {
    let policy = AvailabilityFixtures.scheduledPolicy

    let activeBoundary = try #require(AvailabilityPresentation.nextPlannedBoundary(
        for: policy,
        after: AvailabilityFixtures.referenceDate
    ))
    #expect(activeBoundary == AvailabilityFixtures.referenceDate.addingTimeInterval(31_200))

    let offBoundary = try #require(AvailabilityPresentation.nextPlannedBoundary(
        for: policy,
        after: AvailabilityFixtures.scheduledOffReferenceDate
    ))
    #expect(
        offBoundary
            == AvailabilityFixtures.scheduledOffReferenceDate.addingTimeInterval(6_000)
    )

    #expect(AvailabilityPresentation.nextPlannedBoundary(
        for: AvailabilityFixtures.alwaysPolicy,
        after: AvailabilityFixtures.referenceDate
    ) == nil)
}

@Test("Idle unload defaults to sixty minutes and zero explicitly disables it")
func availabilityIdleUnloadSemantics() {
    var policy = AvailabilityPolicy()
    #expect(policy.idleUnloadMinutes == 60)
    #expect(!policy.idleUnloadingIsDisabled)

    policy.idleUnloadMinutes = 0
    #expect(policy.validation.isValid)
    #expect(policy.idleUnloadingIsDisabled)

    policy.idleUnloadMinutes = -1
    #expect(policy.validation.issues.contains(.invalidIdleUnloadMinutes))
}

@Test("Runtime adapter keeps process observation separate from persistent policy")
func availabilityRuntimeAdapterDoesNotInferPolicy() {
    var provider = ProviderPreviewScenario.scheduledOff.snapshot
    provider.availability.summary = "Coordinator-authored prose must not become policy"

    let runtime = AvailabilityRuntimeSnapshot(providerSnapshot: provider)
    #expect(runtime.state == .scheduledOff)
    #expect(runtime.nextObservedTransitionAt == provider.availability.nextChangeAt)
    #expect(runtime.unifiedLocalEndpointIsReachable == nil)

    provider.availability.summary = "Different prose"
    #expect(AvailabilityRuntimeSnapshot(providerSnapshot: provider) == runtime)
}

@Test("Local API relationship distinguishes unified and standalone modes")
func availabilityLocalAPIFactsStayModeSpecific() {
    #expect(Set(AvailabilityLocalAPIBehavior.allCases) == [
        .unifiedEndpointFollowsSchedule,
        .standaloneLocalIsIndependent,
    ])
}
