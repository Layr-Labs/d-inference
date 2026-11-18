import Darwin
import Foundation
import Testing
@testable import ProviderCore

/// Network serving runs only in a process the provider's launchd service
/// started, from kernel facts (`ServiceLaunchCheck`).
@Suite struct ServiceLaunchCheckTests {
    private static let ours = ServiceLaunchCheck.Signer(teamID: "TEAM123456", identifier: "io.darkbloom.provider")
    private static let shell = ServiceLaunchCheck.Signer(teamID: nil, identifier: "com.apple.zsh")
    private static let launcher = ServiceLaunchCheck.Signer(teamID: "OTHERTEAM1", identifier: "com.example.launcher")
    private static let launchdVersion: Int32 = 7

    private static func process(_ pid: Int32, parent: Int32, version: Int32, original: Int32?,
                                signer: ServiceLaunchCheck.Signer? = ours) -> ServiceLaunchCheck.Process {
        .init(pid: pid, parent: parent, version: version, originalParentVersion: original, signer: signer)
    }

    private static func verdict(_ chain: [ServiceLaunchCheck.Process],
                                serviceName: String? = LaunchAgent.label) -> ServiceLaunchCheck.Verdict {
        ServiceLaunchCheck.verdict(chain: chain, launchdVersion: launchdVersion, serviceName: serviceName,
                                   isProviderJob: ServiceLaunchCheck.isProviderJob)
    }

    @Test func theProvidersJobServes() {
        #expect(Self.verdict([Self.process(100, parent: 1, version: 50, original: Self.launchdVersion)]) == .serve)
        // A kernel before macOS 15.4 does not report the original parent.
        #expect(Self.verdict([Self.process(100, parent: 1, version: 50, original: nil)]) == .serve)
        let clusterService = BuildEnvironment.current.clusterServiceLabelPrefix + "a1b2c3"
        #expect(Self.verdict([Self.process(100, parent: 1, version: 50, original: Self.launchdVersion)],
                             serviceName: clusterService) == .serve)
    }

    @Test func aCopyLaunchdAdoptedIsRefused() {
        #expect(Self.verdict([Self.process(100, parent: 1, version: 50, original: 41)]) == .refuse(.adopted))
    }

    @Test func aJobThatIsNotTheProvidersIsRefused() {
        let me = [Self.process(100, parent: 1, version: 50, original: Self.launchdVersion)]
        #expect(Self.verdict(me, serviceName: "com.example.agent") == .refuse(.notTheProviderJob))
        #expect(Self.verdict(me, serviceName: WatchdogAgent.label) == .refuse(.notTheProviderJob))
        #expect(Self.verdict(me, serviceName: nil) == .refuse(.notTheProviderJob))
        #expect(Self.verdict(me, serviceName: "0") == .refuse(.notTheProviderJob))
    }

    @Test func aCopyAnotherProgramStartedIsRefused() {
        // From a terminal: the shell is its parent.
        #expect(Self.verdict([Self.process(100, parent: 90, version: 50, original: 41),
                              Self.process(90, parent: 80, version: 41, original: 30, signer: Self.shell)],
                             serviceName: "0") == .refuse(.startedByAnotherProgram))
        // From another program that launchd started.
        #expect(Self.verdict([Self.process(100, parent: 90, version: 50, original: 41),
                              Self.process(90, parent: 1, version: 41, original: Self.launchdVersion,
                                           signer: Self.launcher)]) == .refuse(.startedByAnotherProgram))
        // Through a copy of this program that another program started.
        #expect(Self.verdict([Self.process(100, parent: 90, version: 50, original: 41),
                              Self.process(90, parent: 80, version: 41, original: 30),
                              Self.process(80, parent: 1, version: 30, original: Self.launchdVersion,
                                           signer: Self.launcher)]) == .refuse(.startedByAnotherProgram))
        // An unsigned or invalid copy, and no facts at all.
        #expect(Self.verdict([Self.process(100, parent: 1, version: 50, original: Self.launchdVersion,
                                           signer: nil)]) == .refuse(.unknown))
        #expect(Self.verdict([]) == .refuse(.unknown))
    }

    @Test func aPartOfALaunchdStartedServiceServes() {
        // The always-on member under its supervisor (the provider's job).
        #expect(Self.verdict([Self.process(100, parent: 90, version: 50, original: 41),
                              Self.process(90, parent: 1, version: 41, original: Self.launchdVersion)],
                             serviceName: LaunchAgent.label) == .serve)
        // A pair's member under the cluster service under its supervisor; also on a kernel before macOS 15.4.
        for original: Int32? in [Self.launchdVersion, nil] {
            #expect(Self.verdict([Self.process(100, parent: 90, version: 50, original: original.map { _ in 41 }),
                                  Self.process(90, parent: 80, version: 41, original: original.map { _ in 30 }),
                                  Self.process(80, parent: 1, version: 30, original: original)],
                                 serviceName: nil) == .serve)
        }
    }

    @Test func aPartWhoseServiceLaunchdAdoptedOrWhoseParentChangedIsRefused() {
        #expect(Self.verdict([Self.process(100, parent: 90, version: 50, original: 41),
                              Self.process(90, parent: 1, version: 41, original: 12)]) == .refuse(.adopted))
        // The pid it names as parent now belongs to another process.
        #expect(Self.verdict([Self.process(100, parent: 90, version: 50, original: 41),
                              Self.process(90, parent: 1, version: 44, original: Self.launchdVersion)])
                == .refuse(.startedByAnotherProgram))
        // The facts stop before launchd's child.
        #expect(Self.verdict([Self.process(100, parent: 90, version: 50, original: 41),
                              Self.process(90, parent: 80, version: 41, original: 30)])
                == .refuse(.startedByAnotherProgram))
        #expect(Self.verdict([Self.process(100, parent: 90, version: 50, original: 41),
                              Self.process(91, parent: 1, version: 41, original: Self.launchdVersion)])
                == .refuse(.startedByAnotherProgram))
    }

    @Test func theProvidersJobLabels() {
        #expect(ServiceLaunchCheck.isProviderJob(LaunchAgent.label))
        #expect(ServiceLaunchCheck.isProviderJob(BuildEnvironment.current.clusterServiceLabelPrefix + "0a0b0c"))
        #expect(!ServiceLaunchCheck.isProviderJob(WatchdogAgent.label))
        #expect(!ServiceLaunchCheck.isProviderJob("com.apple.Terminal"))
        #expect(!ServiceLaunchCheck.isProviderJob(""))
    }

    /// The kernel facts of this test process, its parent and launchd.
    @Test func liveFactsDescribeThisProcess() throws {
        let me = try #require(ServiceLaunchCheck.process(getpid()))
        #expect(me.pid == getpid())
        #expect(me.parent == getppid())
        #expect(me.version > 0)
        #expect(me.signer != nil)
        let launchd = try #require(ServiceLaunchCheck.process(1))
        #expect(launchd.parent == 0)
        #expect(launchd.signer?.identifier == "com.apple.xpc.launchd")
        #expect(launchd.signer?.teamID == nil)
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)),
           let parent = ServiceLaunchCheck.process(getppid()), getppid() != 1 {
            #expect(me.originalParentVersion == parent.version)
        }
        let chain = ServiceLaunchCheck.liveChain()
        #expect(chain.first == me)
        #expect(chain.count >= 1 && chain.count <= 8)
        // A test runner is not the provider's service.
        #expect(ServiceLaunchCheck.live(environment: [:]) != .serve)
    }
}
