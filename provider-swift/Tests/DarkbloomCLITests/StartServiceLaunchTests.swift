import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// A release build serves the network only in a process Darkbloom's launchd
/// service started; any other start says so, asks launchd to start the
/// service (not for a part, nor on a macOS without the original parent), and
/// exits (`Start.requireServiceLaunch`).
@Suite struct StartServiceLaunchTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var roles: [Start.ServiceLaunchRole] = []
        func record(_ role: Start.ServiceLaunchRole) { lock.withLock { roles.append(role) } }
        var recorded: [Start.ServiceLaunchRole] { lock.withLock { roles } }
    }

    @Test func aRefusedStartAsksLaunchdForItsServiceAndExits() {
        for refusal in [ServiceLaunchCheck.Refusal.startedByAnotherProgram, .adopted, .notTheProviderJob, .unknown] {
            for role in [Start.ServiceLaunchRole.provider, .memberSupervisor, .part] {
                let started = Calls()
                #expect(throws: ExitCode.failure) {
                    try Start.requireServiceLaunch(role, enforced: true, verdict: { .refuse(refusal) },
                                                   startService: { started.record($0); return true })
                }
                // A part's own service starts it; the jobs are asked for.
                #expect(started.recorded == (role == .part ? [] : [role]))
            }
            let lines = Start.serviceLaunchRefusal(.refuse(refusal))
            #expect(lines?.first?.contains("does not serve the network") == true)
            #expect(lines?.last?.contains("start --local --here") == true)
            // One generic text for each of these reasons.
            #expect(lines == Start.serviceLaunchRefusal(.refuse(.unknown)))
        }
    }

    @Test func aMacOSWithoutTheOriginalParentRefusesWithoutAskingLaunchd() {
        for role in [Start.ServiceLaunchRole.provider, .memberSupervisor, .part] {
            let started = Calls()
            #expect(throws: ExitCode.failure) {
                try Start.requireServiceLaunch(role, enforced: true, verdict: { .refuse(.originalParentUnreported) },
                                               startService: { started.record($0); return true })
            }
            // The service would be refused on this macOS too.
            #expect(started.recorded.isEmpty)
        }
        let lines = Start.serviceLaunchRefusal(.refuse(.originalParentUnreported))
        #expect(lines?.first?.contains("before macOS 15.4") == true)
        // The update advice is the one every other path gives (serving needs macOS 27 for App Attest).
        #expect(lines?.contains(ProviderOnboardingPolicy.upgradeGuidance) == true)
        #expect(lines?.last?.contains("start --local --here") == true)
    }

    @Test func theServiceItselfStartsAsBefore() throws {
        let started = Calls()
        for role in [Start.ServiceLaunchRole.provider, .memberSupervisor, .part] {
            try Start.requireServiceLaunch(role, enforced: true, verdict: { .serve },
                                           startService: { started.record($0); return true })
        }
        #expect(started.recorded.isEmpty)
        #expect(Start.serviceLaunchRefusal(.serve) == nil)
    }

    @Test func aBuildThatDoesNotEnforceItNeverAsks() throws {
        let asked = Calls()
        try Start.requireServiceLaunch(.provider, enforced: false, verdict: { asked.record(.part); return .refuse(.unknown) },
                                       startService: { asked.record($0); return true })
        #expect(asked.recorded.isEmpty)
        // Tests and development run debug builds, which serve from a terminal; release builds enforce it.
        #if DEBUG
        #expect(!ServiceLaunchCheck.enforcedInThisBuild)
        #else
        #expect(ServiceLaunchCheck.enforcedInThisBuild)
        #endif
    }

    // The three network-serving entries refuse first, before anything else runs: a refused start never reaches
    // the running service, its configuration or launchd beyond the one request.

    private static func refusing(_ started: Calls) -> Start.ServiceLaunchTesting {
        .init(verdict: .refuse(.startedByAnotherProgram), startService: { started.record($0); return false })
    }

    @Test func runForegroundRefusesFirst() async throws {
        let started = Calls()
        let hardware = HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 64, memoryAvailableGb: 64, cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let snapshot = RuntimeSnapshot(
            configPath: FileManager.default.temporaryDirectory.appendingPathComponent("service-launch-\(UUID().uuidString).toml"),
            configFileExists: false, config: ProviderConfig(provider: ProviderSettings(name: "service-launch-fixture")),
            hardware: hardware, hardwareError: nil, models: [])
        let start = try Start.parse(["--foreground"])
        await #expect(throws: ExitCode.failure) {
            try await Start.$serviceLaunchForTesting.withValue(Self.refusing(started)) {
                try await start.runForeground(snapshot: snapshot, hardware: hardware, config: snapshot.config,
                                              coordinatorURL: "wss://coordinator.invalid/ws/provider", runtimeCapabilities: [],
                                              bootSecuritySnapshot: BootSecuritySnapshot(macOSMajorVersion: 25, sip: .disabled))
            }
        }
        #expect(started.recorded == [.provider])
    }

    @Test func theMemberSupervisorRefusesFirst() async throws {
        let started = Calls()
        let start = try Start.parse(["--foreground", "--cluster-member", "--supervise",
                                     "--config", "/nonexistent/service-launch/provider.toml"])
        await #expect(throws: ExitCode.failure) {
            try await Start.$serviceLaunchForTesting.withValue(Self.refusing(started)) {
                try await start.runClusterMemberSupervisor()
            }
        }
        #expect(started.recorded == [.memberSupervisor])
    }

    @Test func aClusterMemberRefusesFirstAndAsksForNothing() async throws {
        let started = Calls()
        let start = try Start.parse(["--foreground", "--cluster-member", "--config", "/nonexistent/service-launch/provider.toml"])
        await #expect(throws: ExitCode.failure) {
            try await Start.$serviceLaunchForTesting.withValue(Self.refusing(started)) {
                try await start.runClusterMember()
            }
        }
        #expect(started.recorded.isEmpty)
    }

    @Test func aSessionOnlyClusterServiceSaysItDoesNotServeDarkbloomTraffic() {
        let reason = "launchd could not take the job"
        #expect(OnboardingLive.sessionServiceReason(reason, enforced: true).hasPrefix(reason + "; "))
        #expect(OnboardingLive.sessionServiceReason(reason, enforced: true).contains("does not serve Darkbloom traffic"))
        #expect(OnboardingLive.sessionServiceReason(reason, enforced: false) == reason)
    }
}
