import Foundation
import Testing

@testable import ProviderCore

/// S18: the cluster-member launchd job and the supervision policies it runs.
/// The policies are also covered model-free by Tests/ClusterSupervisionChecks.
@Suite("Cluster member supervision")
struct ClusterMemberSupervisionTests {
    @Test func memberJobRunsTheSupervisorUnderTheProviderLabel() {
        let arguments = LaunchAgent.clusterMemberProgramArguments(
            binaryPath: "/Apps/Darkbloom.app/Contents/MacOS/darkbloom",
            coordinatorURL: "wss://coordinator.invalid/ws/provider",
            configPath: URL(fileURLWithPath: "/fixture/provider.toml"))
        #expect(arguments == ["/Apps/Darkbloom.app/Contents/MacOS/darkbloom", "start", "--foreground", "--cluster-member",
                              "--supervise", "--coordinator-url", "wss://coordinator.invalid/ws/provider",
                              "--config", "/fixture/provider.toml"])
        #expect(LaunchAgent.isClusterMemberJob(arguments))
        let solo = LaunchAgent.serviceProgramArguments(binaryPath: "/b/darkbloom", coordinatorURL: "wss://c",
                                                       models: ["m"], configPath: nil)
        #expect(!LaunchAgent.isClusterMemberJob(solo))
        // The binary path itself never counts, only an argument.
        #expect(!LaunchAgent.isClusterMemberJob(["/x/--cluster-member", "start"]))
    }

    @Test func memberJobKeepsTheSoloServiceShape() {
        let plist = LaunchAgent.makeServicePlist(
            label: LaunchAgent.label,
            programArguments: LaunchAgent.clusterMemberProgramArguments(binaryPath: "/b/darkbloom",
                coordinatorURL: "wss://c", configPath: nil),
            logPath: "/tmp/provider.log", environment: [:])
        // RunAtLoad brings the member back after a reboot; KeepAlive stays off
        // because the supervisor (and, behind it, the watchdog) owns restarts.
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == false)
        #expect(plist["ExitTimeOut"] as? Int == 3660)
        #expect((plist["ProgramArguments"] as? [String])?.contains("--supervise") == true)
    }

    @Test func installedJobRoleIsReadFromThePlist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("s18-plist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let member = directory.appendingPathComponent("member.plist")
        let solo = directory.appendingPathComponent("solo.plist")
        for (url, arguments) in [(member, LaunchAgent.clusterMemberProgramArguments(binaryPath: "/b/darkbloom",
                                                                                   coordinatorURL: "wss://c", configPath: nil)),
                                 (solo, LaunchAgent.serviceProgramArguments(binaryPath: "/b/darkbloom", coordinatorURL: "wss://c",
                                                                            models: [], configPath: nil))] {
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "x", "ProgramArguments": arguments],
                                                          format: .xml, options: 0)
            try data.write(to: url)
        }
        #expect(LaunchAgent.installedJobIsClusterMember(at: member))
        #expect(!LaunchAgent.installedJobIsClusterMember(at: solo))
        #expect(!LaunchAgent.installedJobIsClusterMember(at: directory.appendingPathComponent("absent.plist")))
    }

    @Test func budgetMatchesTheOwnersRestartLoop() {
        var budget = ClusterMemberRestartBudget()
        #expect(budget.record(.failure(exitCode: 1), runSeconds: 3) == .restart(afterSeconds: 15))
        #expect(budget.record(.signaled(15), runSeconds: 10) == .restart(afterSeconds: 30))
        guard case .exhausted = budget.record(.failure(exitCode: 0), runSeconds: 1) else {
            Issue.record("a third quick failure must exhaust the budget"); return
        }
        var served = ClusterMemberRestartBudget()
        _ = served.record(.failure(exitCode: 1), runSeconds: 3)
        #expect(served.record(.failure(exitCode: 1), runSeconds: 3_600) == .restart(afterSeconds: 15))
        #expect(served.record(.operatorStop, runSeconds: 1) == .stop)
    }

    @Test func heartbeatGuardRecyclesAWedgedMemberOnly() {
        var guardState = ClusterMemberLivenessGuard()
        let beat = ClusterMemberHealth(pid: 5, version: "v", phase: .registered, writtenAt: 1_000)
        #expect(guardState.observe(health: beat, childPID: 5, runStartedAt: 0, now: 1_074) == .healthy)
        guard case .recycle = guardState.observe(health: beat, childPID: 5, runStartedAt: 0, now: 1_075) else {
            Issue.record("a heartbeat 75 s old after the grace must recycle"); return
        }
    }

    @Test func linkGateWaitsForTheSavedDevice() {
        #expect(ClusterMemberLinkGate.decide(machine: .ready, device: .ready, probeFailingForSeconds: 0) == .ready)
        #expect(ClusterMemberLinkGate.decide(machine: .ready, device: .portWithoutIPv4Address, probeFailingForSeconds: 0)
            == .wait(.portWithoutIPv4Address))
        #expect(ClusterMemberLinkGate.decide(machine: .rdmaDisabled, device: nil, probeFailingForSeconds: 0)
            == .blocked(.rdmaDisabled))
    }

    @Test func bothMembersComputeTheSameUpdateSlot() {
        let now = 1_791_745_755.0
        let first = ClusterMemberUpdateSlot.nextSlot(after: now, clusterID: "pair-a")
        let second = ClusterMemberUpdateSlot.nextSlot(after: now + 3, clusterID: "pair-a")
        #expect(first == second)
        #expect(ClusterMemberUpdateSlot.decide(now: first, slot: first, busy: false) == .check)
    }
}
