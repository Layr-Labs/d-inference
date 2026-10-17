// Model-free checks of the cluster-member supervision policies (S18): the
// restart budget and backoff ported from the owner's production restart loop,
// the liveness guard, the link gate, the coordinated update slot, the shared
// files and the supervisor state summary. Compiled with plain swiftc by
// run.sh against the policy sources only; no MLX, no network, no launchd.

import Foundation

var failures = 0
var checks = 0
@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

// MARK: - Run classification

check(ClusterMemberRunEnd.classify(stopRequested: true, exitCode: 1, signal: nil) == .operatorStop,
      "a stop the supervisor asked for wins over any exit status")
check(ClusterMemberRunEnd.classify(stopRequested: false, exitCode: 0, signal: nil) == .failure(exitCode: 0),
      "an unrequested clean exit is a crash, not an operator stop")
check(ClusterMemberRunEnd.classify(stopRequested: false, exitCode: 75, signal: nil) == .guardTeardown,
      "exit 75 is the JACCL guard's teardown")
check(ClusterMemberRunEnd.classify(stopRequested: false, exitCode: nil, signal: 9) == .signaled(9),
      "a signal the supervisor did not send is reported as such")

// MARK: - Restart budget: the owner's auto_restart.sh shape

do {
    var budget = ClusterMemberRestartBudget()
    // Three quick failures: restart after 15 s, then 30 s, then stop.
    check(budget.record(.failure(exitCode: 1), runSeconds: 5) == .restart(afterSeconds: 15), "first quick failure waits 15 s")
    check(budget.record(.failure(exitCode: 1), runSeconds: 5) == .restart(afterSeconds: 30), "second quick failure waits 30 s")
    if case .exhausted(let reason) = budget.record(.failure(exitCode: 1), runSeconds: 5) {
        check(reason.contains("3 quick failures"), "the reason names the breaker: \(reason)")
    } else {
        check(false, "third quick failure must exhaust the budget")
    }
    check(budget.quickFailures == 3 && budget.restartsIssued == 2, "two restarts were issued before the breaker")
}

do {
    var budget = ClusterMemberRestartBudget()
    // A long run resets the counters and the backoff (killed member while serving).
    _ = budget.record(.failure(exitCode: 1), runSeconds: 10)
    _ = budget.record(.failure(exitCode: 1), runSeconds: 10)
    check(budget.backoffSeconds == 60, "backoff doubled twice")
    check(budget.record(.signaled(15), runSeconds: 600) == .restart(afterSeconds: 15), "a run of 600 s resets to 15 s")
    check(budget.quickFailures == 0 && budget.guardTeardowns == 0, "counters reset by a long run")
    check(budget.backoffSeconds == 30, "next wait doubles from the reset value")
}

do {
    var budget = ClusterMemberRestartBudget()
    // Backoff caps at 300 s: alternate long runs never trip, quick ones double.
    var waits: [Int] = []
    for _ in 0..<2 { if case .restart(let wait) = budget.record(.failure(exitCode: 2), runSeconds: 1) { waits.append(wait) } }
    _ = budget.record(.failure(exitCode: 2), runSeconds: 121)
    for _ in 0..<2 { if case .restart(let wait) = budget.record(.failure(exitCode: 2), runSeconds: 1) { waits.append(wait) } }
    check(waits == [15, 30, 30, 60], "waits after a reset: \(waits)")
}

do {
    var budget = ClusterMemberRestartBudget(limits: .init(maxQuickFailures: 100))
    var last = 0
    for _ in 0..<10 { if case .restart(let wait) = budget.record(.failure(exitCode: 2), runSeconds: 1) { last = wait } }
    check(last == 300, "backoff is capped at 300 s, got \(last)")
}

do {
    var budget = ClusterMemberRestartBudget()
    // Guard teardowns have their own budget of six and do not count as startup failures.
    var decisions: [ClusterMemberRestartBudget.Decision] = []
    for _ in 0..<6 { decisions.append(budget.record(.guardTeardown, runSeconds: 20)) }
    check(budget.quickFailures == 0, "teardowns are not quick failures")
    if case .exhausted(let reason) = decisions.last! {
        check(reason.contains("flapping"), "sixth teardown in the window stops: \(reason)")
    } else {
        check(false, "sixth guard teardown must exhaust the budget")
    }
    check(decisions.prefix(5).allSatisfy { if case .restart = $0 { return true } else { return false } },
          "the first five teardowns restart")
}

do {
    var budget = ClusterMemberRestartBudget()
    check(budget.record(.operatorStop, runSeconds: 1) == .stop, "an operator stop never restarts")
    check(budget.restartsIssued == 0 && budget.quickFailures == 0, "and counts nothing")
}

do {
    let limits = ClusterMemberRestartBudget.Limits.resolve([
        "DARKBLOOM_CLUSTER_RESTART_WINDOW_SECONDS": "30",
        "DARKBLOOM_CLUSTER_RESTART_BACKOFF_INITIAL_SECONDS": "2",
        "DARKBLOOM_CLUSTER_RESTART_BACKOFF_MAX_SECONDS": "x",
    ])
    check(limits.quickFailureWindowSeconds == 30 && limits.initialBackoffSeconds == 2, "test overrides apply")
    check(limits.maxBackoffSeconds == 300 && limits.maxQuickFailures == 3, "invalid or absent overrides keep production")
    check(ClusterMemberRestartBudget.Limits.resolve([:]) == .production, "no environment is production")
}

do {
    // The budget survives the state file round trip.
    var budget = ClusterMemberRestartBudget()
    _ = budget.record(.failure(exitCode: 1), runSeconds: 3)
    let data = try! JSONEncoder().encode(budget)
    let decoded = try! JSONDecoder().decode(ClusterMemberRestartBudget.self, from: data)
    check(decoded == budget, "budget Codable round trip")
}

// MARK: - Liveness guard

do {
    var guardState = ClusterMemberLivenessGuard()
    let start = 1_000.0
    func beat(_ at: Double, pid: Int32 = 42, active: ClusterMemberHealth.ActiveRequest? = nil) -> ClusterMemberHealth {
        ClusterMemberHealth(pid: pid, version: "t", phase: .registered, writtenAt: at, activeRequest: active)
    }
    check(guardState.observe(health: nil, childPID: 42, runStartedAt: start, now: start + 10) == .starting,
          "no heartbeat inside the start grace is starting")
    check(guardState.observe(health: beat(start + 170), childPID: 42, runStartedAt: start, now: start + 175) == .healthy,
          "a fresh heartbeat is healthy")
    // Heartbeat stops at +200; at +250 it is 50 s old (inside the 75 s budget).
    check(guardState.observe(health: beat(start + 200), childPID: 42, runStartedAt: start, now: start + 250) == .healthy,
          "50 s old is still fresh (busy is not dead)")
    check(guardState.observe(health: beat(start + 200), childPID: 42, runStartedAt: start, now: start + 274) == .healthy,
          "74 s old is still inside the down budget")
    if case .recycle(let reason) = guardState.observe(health: beat(start + 200), childPID: 42, runStartedAt: start, now: start + 276) {
        check(reason.contains("heartbeat missing for 76 s"), "recycle names the missing heartbeat: \(reason)")
    } else { check(false, "76 s without a heartbeat recycles (down measured from the last beat)") }
}

do {
    var guardState = ClusterMemberLivenessGuard()
    let stale = ClusterMemberHealth(pid: 7, version: "t", phase: .serving, writtenAt: 5_000)
    // A heartbeat of the previous process is ignored: inside grace that is "starting".
    check(guardState.observe(health: stale, childPID: 8, runStartedAt: 5_000, now: 5_010) == .starting,
          "another pid's heartbeat does not count")
    // After the grace with still no own heartbeat the down timer starts now and recycles 75 s later.
    if case .downFor(let seconds) = guardState.observe(health: stale, childPID: 8, runStartedAt: 5_000, now: 5_200) {
        check(seconds == 0, "down timer starts at the first observation, got \(seconds)")
    } else { check(false, "past grace without a heartbeat is down") }
    if case .recycle = guardState.observe(health: stale, childPID: 8, runStartedAt: 5_000, now: 5_276) {} else {
        check(false, "75 s after the first down observation recycles")
    }
    check(guardState.observe(health: ClusterMemberHealth(pid: 8, version: "t", phase: .registered, writtenAt: 5_280),
                             childPID: 8, runStartedAt: 5_000, now: 5_281) == .healthy, "a heartbeat clears the timer")
    check(guardState.downSince == nil, "down timer cleared")
}

do {
    let limits = ClusterMemberLivenessGuard.Limits.production
    check(limits.noStartLimit(promptTokens: 0) == 120, "no-start floor 120 s")
    check(limits.noStartLimit(promptTokens: 300_000) == 420, "300k-token prompt gets 420 s")
    check(limits.noStartLimit(promptTokens: 10_000_000) == 900, "no-start cap 900 s")
    var guardState = ClusterMemberLivenessGuard()
    let stuck = ClusterMemberHealth.ActiveRequest(id: "r1", secondsSinceProgress: 130, tokensEmitted: 0,
                                                  prefillProcessedTokens: 0, promptTokens: 4_000)
    let beat = ClusterMemberHealth(pid: 9, version: "t", phase: .serving, writtenAt: 9_000, activeRequest: stuck)
    check(guardState.observe(health: beat, childPID: 9, runStartedAt: 8_900, now: 9_001) == .healthy,
          "the no-start signal is ignored inside the start grace (stale handover)")
    if case .recycle(let reason) = guardState.observe(health: beat, childPID: 9, runStartedAt: 8_000, now: 9_001) {
        check(reason.contains("r1") && reason.contains("no prefill or decode progress"), "no-start recycle: \(reason)")
    } else { check(false, "a request with no progress past its limit recycles") }
    let progressing = ClusterMemberHealth.ActiveRequest(id: "r2", secondsSinceProgress: 500, tokensEmitted: 3,
                                                        prefillProcessedTokens: 4_000, promptTokens: 4_000)
    check(guardState.observe(health: ClusterMemberHealth(pid: 9, version: "t", phase: .serving, writtenAt: 9_000,
                                                         activeRequest: progressing),
                             childPID: 9, runStartedAt: 8_000, now: 9_001) == .healthy,
          "a request that started is never a no-start")
}

do {
    let limits = ClusterMemberLivenessGuard.Limits.resolve(["DARKBLOOM_CLUSTER_GUARD_START_GRACE_SECONDS": "20",
                                                            "DARKBLOOM_CLUSTER_GUARD_DOWN_SECONDS": "-1"])
    check(limits.startGraceSeconds == 20 && limits.downSeconds == 75, "guard overrides: positive only")
}

do {
    var guardState = ClusterMemberLivenessGuard()
    func beat(wedged: Double?) -> ClusterMemberHealth {
        ClusterMemberHealth(pid: 4, version: "t", phase: .serving, writtenAt: 10_000, engineWedgedSeconds: wedged)
    }
    check(guardState.observe(health: beat(wedged: 179), childPID: 4, runStartedAt: 9_000, now: 10_001) == .healthy,
          "an engine wedged for less than 180 s is left to its own recovery")
    if case .recycle(let reason) = guardState.observe(health: beat(wedged: 180), childPID: 4, runStartedAt: 9_000, now: 10_001) {
        check(reason.contains("wedged for 180 s"), "wedge recycle: \(reason)")
    } else { check(false, "an engine wedged for 180 s recycles the member") }
    check(guardState.observe(health: beat(wedged: 500), childPID: 4, runStartedAt: 9_950, now: 10_001) == .healthy,
          "the wedge signal respects the start grace")
}

// MARK: - Link gate

check(ClusterMemberLinkGate.decide(machine: .ready, device: .ready, probeFailingForSeconds: 0) == .ready, "ready starts")
check(ClusterMemberLinkGate.decide(machine: .noActivePort, device: .noActivePort, probeFailingForSeconds: 0)
      == .wait(.noActivePort), "no active port waits")
check(ClusterMemberLinkGate.decide(machine: .ready, device: .portBridgedWithoutAddress, probeFailingForSeconds: 0)
      == .wait(.portBridgedWithoutAddress), "the saved device's verdict decides, not another port's")
// Link setup v2: RDMA needs an IPv4-mapped GID on the port itself. A port still without its own
// address, or whose GID macOS has not published yet, is waited for (one-time setup or late boot),
// never started into a JACCL "No IPv4-mapped GID" failure.
check(ClusterMemberLinkGate.decide(machine: .ready, device: .portWithoutIPv4Address, probeFailingForSeconds: 0)
      == .wait(.portWithoutIPv4Address), "a port without its own IPv4 address waits for link setup")
check(ClusterMemberLinkGate.decide(machine: .ready, device: .gidNotPublished, probeFailingForSeconds: 0)
      == .wait(.gidNotPublished), "a port whose IPv4-mapped GID is not published yet waits")
check(ClusterMemberLinkGate.decide(machine: .gidNotPublished, device: .ready, probeFailingForSeconds: 0) == .ready,
      "another port's missing GID does not hold the saved device")
check(ClusterMemberLinkGate.decide(machine: .ready, device: nil, probeFailingForSeconds: 0) == .wait(.probeFailed),
      "a device this Mac does not list waits like a failed reading")
check(ClusterMemberLinkGate.decide(machine: .rdmaDisabled, device: nil, probeFailingForSeconds: 0) == .blocked(.rdmaDisabled),
      "RDMA off is blocked, not waited for quickly")
check(ClusterMemberLinkGate.decide(machine: .probeFailed, device: .ready, probeFailingForSeconds: 59) == .wait(.probeFailed),
      "failed readings wait up to a minute")
check(ClusterMemberLinkGate.decide(machine: .probeFailed, device: nil, probeFailingForSeconds: 60) == .proceedUnverified,
      "then the start goes ahead and JACCL decides")
check(ClusterMemberLinkGate.shouldLog(state: .noActivePort, previous: .noActivePort, secondsSinceLastLog: 10) == false,
      "same state within a minute is not logged again")
check(ClusterMemberLinkGate.shouldLog(state: .gidNotPublished, previous: .noActivePort, secondsSinceLastLog: 1),
      "a changed state is logged at once")

// MARK: - Coordinated update slot

do {
    let a = ClusterMemberUpdateSlot.stableOffset(clusterID: "cluster-1")
    check(a == ClusterMemberUpdateSlot.stableOffset(clusterID: "cluster-1"), "offset is stable")
    check(a >= 0 && a < ClusterMemberUpdateSlot.periodSeconds, "offset inside the period")
    // FNV-1a 64 of "cluster-1" mod 1800, computed independently in run.sh with python.
    if let expected = ProcessInfo.processInfo.environment["EXPECTED_FNV_OFFSET"], let value = Double(expected) {
        check(a == value, "offset matches an independent FNV-1a computation: \(a) vs \(value)")
    }
    let now = 1_760_000_000.0
    let slot = ClusterMemberUpdateSlot.nextSlot(after: now, clusterID: "cluster-1")
    check(slot > now && slot - now <= ClusterMemberUpdateSlot.periodSeconds, "next slot within one period")
    check(ClusterMemberUpdateSlot.nextSlot(after: now + 7, clusterID: "cluster-1") == slot,
          "both Macs (seconds apart) pick the same slot")
    check(ClusterMemberUpdateSlot.nextSlot(after: slot, clusterID: "cluster-1") == slot + ClusterMemberUpdateSlot.periodSeconds,
          "the slot after a slot is one period later")
    check((slot - ClusterMemberUpdateSlot.stableOffset(clusterID: "cluster-1"))
          .truncatingRemainder(dividingBy: ClusterMemberUpdateSlot.periodSeconds) == 0, "slots sit on the offset grid")
    check(ClusterMemberUpdateSlot.decide(now: slot - 1, slot: slot, busy: false) == .wait(until: slot), "not due before the slot")
    check(ClusterMemberUpdateSlot.decide(now: slot, slot: slot, busy: false) == .check, "idle at the slot checks")
    check(ClusterMemberUpdateSlot.decide(now: slot + 5, slot: slot, busy: true) == .deferBusy(retryAt: slot + 20), "busy defers")
    check(ClusterMemberUpdateSlot.decide(now: slot + 601, slot: slot, busy: true) == .skip, "busy past 10 min skips the slot")
}

// MARK: - Files and state summary

do {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("s18-checks-\(getpid())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let healthURL = directory.appendingPathComponent("health.json")
    let health = ClusterMemberHealth(pid: 3, version: "v", phase: .serving, writtenAt: 1, registeredAt: 0.5,
                                     servingSince: 0.9, warmup: "ok")
    check(ClusterSupervisionFiles.write(health, to: healthURL), "health write")
    check(ClusterSupervisionFiles.read(ClusterMemberHealth.self, from: healthURL) == health, "health round trip")
    let mode = (try? FileManager.default.attributesOfItem(atPath: healthURL.path)[.posixPermissions] as? NSNumber)?.intValue
    check(mode == 0o600, "owner-only file, got \(String(mode ?? -1, radix: 8))")
    try? Data("not json".utf8).write(to: healthURL)
    check(ClusterSupervisionFiles.read(ClusterMemberHealth.self, from: healthURL) == nil, "a corrupt file reads as nil")
    let statePath = ClusterSupervisionFiles.statePath(environment: ["DARKBLOOM_CLUSTER_SUPERVISOR_STATE": "/tmp/x/state.json"])
    check(statePath.path == "/tmp/x/state.json", "state path override")
    check(ClusterSupervisionFiles.lockPath(forState: statePath).path == "/tmp/x/state.lock", "lock beside the state")
    let home = URL(fileURLWithPath: "/Users/someone")
    check(ClusterSupervisionFiles.statePath(environment: [:], home: home).path == "/Users/someone/.darkbloom/cluster-supervisor.json",
          "default state path")
}

do {
    var budget = ClusterMemberRestartBudget()
    _ = budget.record(.failure(exitCode: 1), runSeconds: 2)
    let state = ClusterMemberSupervisorState(supervisorPID: 1, version: "v", bootTime: 0, phase: .backoff,
        budget: budget, lastRun: .init(pid: 5, startedAt: 10, endedAt: 12, exitCode: 1, end: "failure"),
        runs: 1, restartAt: 112, updatedAt: 100)
    let line = state.summary(now: 100)
    check(line.contains("backoff") && line.contains("restart in 12 s") && line.contains("quick failures 1/3"),
          "summary: \(line)")
}

// MARK: - Permissions asked once: the code identity macOS keys approvals on

do {
    let app = "/Users/someone/.darkbloom/Darkbloom.app"
    let exe = app + "/Contents/MacOS/darkbloom"
    let release: [String: Any] = ["CFBundleIdentifier": "io.darkbloom.provider",
                                  "NSLocalNetworkUsageDescription": "Darkbloom connects to the other Macs of your cluster."]
    let signed = ClusterMemberPermissionIdentity.classify(executablePath: exe, signatureReadable: true, flags: 0x10000,
        leafCertificateSummary: "Developer ID Application: Example (TEAM123456)", teamIdentifier: "TEAM123456", infoPlist: release)
    check(signed.verdict == .askedOnce && signed.problems.isEmpty, "signed release in the app with the usage string: asked once")
    check(signed.bundlePath == app && signed.bundleIdentifier == "io.darkbloom.provider", "bundle found: \(signed.bundlePath ?? "nil")")
    check(signed.summary.contains("asked once") && signed.summary.contains("team TEAM123456"), "summary: \(signed.summary)")

    var older = release; older["NSLocalNetworkUsageDescription"] = nil
    let oldRelease = ClusterMemberPermissionIdentity.classify(executablePath: exe, signatureReadable: true, flags: 0x10000,
        leafCertificateSummary: "Developer ID Application: Example (TEAM123456)", teamIdentifier: "TEAM123456", infoPlist: older)
    check(oldRelease.verdict == .perBuild && oldRelease.problems.count == 1
          && oldRelease.problems[0].contains("NSLocalNetworkUsageDescription"), "a release without the usage string cannot ask")
    var blank = release; blank["NSLocalNetworkUsageDescription"] = "  "
    check(ClusterMemberPermissionIdentity.classify(executablePath: exe, signatureReadable: true, flags: 0,
        leafCertificateSummary: "Developer ID Application: X", teamIdentifier: "T", infoPlist: blank).verdict == .perBuild,
          "a blank usage string does not count")

    let adHoc = ClusterMemberPermissionIdentity.classify(executablePath: "/opt/build/debug/darkbloom", signatureReadable: true,
        flags: 0x20002, leafCertificateSummary: nil, teamIdentifier: nil, infoPlist: nil)
    check(adHoc.signing == .adHoc && adHoc.verdict == .perBuild && adHoc.problems.count == 2, "ad-hoc build outside a bundle: \(adHoc.problems)")
    check(adHoc.problems[0].contains("ad-hoc") && adHoc.problems[1].contains("not inside Darkbloom.app"), "problems ordered: \(adHoc.problems)")
    check(adHoc.bundleIdentifier == nil && !adHoc.hasLocalNetworkUsageDescription, "no bundle, no usage string")

    let adHocInApp = ClusterMemberPermissionIdentity.classify(executablePath: exe, signatureReadable: true, flags: 0x2,
        leafCertificateSummary: nil, teamIdentifier: nil, infoPlist: release)
    check(adHocInApp.verdict == .perBuild && adHocInApp.problems.count == 1, "ad-hoc in a bundle is still per build")
    let development = ClusterMemberPermissionIdentity.classify(executablePath: exe, signatureReadable: true, flags: 0,
        leafCertificateSummary: "Apple Development: someone", teamIdentifier: "T", infoPlist: release)
    check(development.signing == .otherCertificate && development.verdict == .perBuild, "a development certificate is not Developer ID")
    let unsigned = ClusterMemberPermissionIdentity.classify(executablePath: exe, signatureReadable: true, flags: nil,
        leafCertificateSummary: nil, teamIdentifier: nil, infoPlist: release)
    check(unsigned.signing == .unsigned, "no identifier: unsigned")

    // Round 5 (hardware o1, ad-hoc bench build): a login agent's member was refused the link ("may not reach the
    // local network") and onboarding never served. The onboarding keeps the service in the session for such a build.
    check(signed.launchdLinkRefusal == nil, "signed release in the app: launchd's member can reach the link")
    check(development.launchdLinkRefusal == nil, "another certificate (firewall problem only) does not stop the link")
    check(adHoc.launchdLinkRefusal?.contains("ad-hoc signed; the executable is not inside Darkbloom.app") == true
          && adHoc.launchdLinkRefusal?.contains("Local Network") == true, "ad-hoc outside a bundle: \(adHoc.launchdLinkRefusal ?? "nil")")
    check(adHocInApp.launchdLinkRefusal?.hasPrefix("this build is ad-hoc signed:") == true, "ad-hoc in a bundle: refused")
    check(unsigned.launchdLinkRefusal?.hasPrefix("this build is unsigned:") == true, "unsigned: refused")
    check(oldRelease.launchdLinkRefusal?.hasPrefix("Darkbloom.app carries no NSLocalNetworkUsageDescription:") == true,
          "a release without the usage string: refused")
    check(ClusterMemberPermissionIdentity.classify(executablePath: exe, signatureReadable: false, flags: nil,
        leafCertificateSummary: nil, teamIdentifier: nil, infoPlist: release).launchdLinkRefusal?.contains("could not be read") == true,
          "an unreadable signature: refused")
    check(ClusterMemberPermissionIdentity.classify(executablePath: exe, signatureReadable: false, flags: nil,
        leafCertificateSummary: nil, teamIdentifier: nil, infoPlist: release).signing == .unknown, "unreadable signature: unknown")

    check(ClusterMemberPermissionIdentity.enclosingAppBundle(of: "/A/Darkbloom.app/Contents/MacOS/darkbloom") == "/A/Darkbloom.app", "bundle path")
    check(ClusterMemberPermissionIdentity.enclosingAppBundle(of: "/A/Darkbloom.app/Contents/Helpers/darkbloom-cluster-worker") == nil,
          "a helper is not the bundle's main executable")
    check(ClusterMemberPermissionIdentity.enclosingAppBundle(of: "/A/bin/darkbloom") == nil, "plain directory")
    check(ClusterMemberPermissionIdentity.enclosingAppBundle(of: "/A/Darkbloom.app/Contents/MacOS/../MacOS/darkbloom") == "/A/Darkbloom.app",
          "standardized path")

    // Live probe of real executables when asked (model-free; reads signatures only).
    for path in (ProcessInfo.processInfo.environment["PERMISSION_PROBE_PATHS"] ?? "").split(separator: ":").map(String.init) {
        let live = ClusterMemberPermissionIdentity.current(executablePath: path)
        print("probe \((path as NSString).lastPathComponent) in \(live.bundlePath == nil ? "no bundle" : "a bundle"): \(live.summary)")
    }
}

// MARK: - Cluster service login agent (review finding 12)

do {
    typealias Plan = ClusterServiceAgentPlan
    // The install root: the outermost app bundle, else the binary's folder.
    check(Plan.installRoot(executablePath: "/Applications/Darkbloom.app/Contents/MacOS/darkbloom") == "/Applications/Darkbloom.app",
          "app binary: the bundle is the install")
    check(Plan.installRoot(executablePath: "/Applications/Darkbloom.app/Contents/Helpers/darkbloom") == "/Applications/Darkbloom.app",
          "a binary in Contents/Helpers belongs to the same install")
    check(Plan.installRoot(executablePath: "/A/Darkbloom.app/Contents/Helpers/X.app/Contents/MacOS/x") == "/A/Darkbloom.app",
          "a nested helper app belongs to the outer install")
    check(Plan.installRoot(executablePath: "/w/.build/debug/darkbloom") == "/w/.build/debug", "development build: its folder")
    check(Plan.installRoot(executablePath: "/A/Darkbloom.app/Contents/MacOS/../MacOS/darkbloom") == "/A/Darkbloom.app", "standardized")
    check(Plan.installRoot(executablePath: "/A/Notes.app.d/darkbloom") == "/A/Notes.app.d", "a folder named like a bundle is not one")

    // The label: scoped to the install, stable, and recognizable as ours.
    let app = Plan.label(executablePath: "/Applications/Darkbloom.app/Contents/MacOS/darkbloom")
    check(app == Plan.label(executablePath: "/Applications/Darkbloom.app/Contents/Helpers/darkbloom"), "one label per install")
    check(app != Plan.label(executablePath: "/Volumes/Other/Applications/Darkbloom.app/Contents/MacOS/darkbloom"), "another install, another label")
    check(app != Plan.label(executablePath: "/w/.build/debug/darkbloom"), "a development build never shares the release job")
    check(app.hasPrefix(Plan.labelPrefix) && app.count == Plan.labelPrefix.count + 12, "label shape: \(app)")
    check(Plan.isAgentFileName(app + ".plist"), "our file name")
    for other in ["io.darkbloom.provider.plist", "io.darkbloom.cluster-service.plist", Plan.labelPrefix + "ABCDEF012345.plist",
                  Plan.labelPrefix + "abcdef01234.plist", Plan.labelPrefix + "abcdef012345.plist.bak", app] {
        check(!Plan.isAgentFileName(other), "not one of ours: \(other)")
    }

    // What launchd runs (the supervisor) and what the supervisor runs (the service), with the same options.
    let options = Plan.serviceOptions(config: "/c/provider.toml", worker: nil)
    check(options == ["--config", "/c/provider.toml"], "only the given options")
    check(Plan.serviceOptions(config: nil, worker: nil).isEmpty, "the default configuration stays implicit")
    check(Plan.programArguments(executablePath: "/A/darkbloom", serviceOptions: options)
          == ["/A/darkbloom", "cluster", "service", "--supervise", "--config", "/c/provider.toml"], "launchd runs the supervisor")
    check(Plan.childArguments(serviceOptions: options) == ["cluster", "service", "--config", "/c/provider.toml"], "the supervisor runs the service")

    // The job: at login, kept alive only after a crash, throttled by the budget, room for the part to release.
    let plist = Plan.propertyList(label: app, programArguments: ["/A/darkbloom"], logPath: "/h/.darkbloom/cluster-setup/service.log",
                                  environment: [:])
    check(plist["RunAtLoad"] as? Bool == true, "starts at login")
    check((plist["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false], "relaunched only after an unsuccessful exit")
    check(plist["ThrottleInterval"] as? Int == ClusterMemberRestartBudget.Limits.production.initialBackoffSeconds,
          "launchd's relaunch throttle is the budget's first backoff")
    check((plist["ExitTimeOut"] as? Int ?? 0) > Plan.partStopGraceSeconds, "launchd waits longer than the part's own release grace")
    check(plist["EnvironmentVariables"] == nil, "no environment when nothing passes through")
    check(plist["StandardOutPath"] as? String == "/h/.darkbloom/cluster-setup/service.log", "the service log")
    check(plist["UserName"] == nil && plist["GroupName"] == nil, "a per-user agent: no user switch, no privilege")

    // Environment: the allowlist, plus a fixed home only where the host set one.
    check(Plan.environment(passthrough: ["DARKBLOOM_PREFIX_CACHE": "0"], installing: ["PATH": "/bin", "HOME": "/h"])
          == ["DARKBLOOM_PREFIX_CACHE": "0"], "nothing but the allowlist")
    check(Plan.environment(passthrough: [:], installing: ["CFFIXED_USER_HOME": "/redirected"]) == ["CFFIXED_USER_HOME": "/redirected"],
          "a redirected home follows the service")
    check(Plan.environment(passthrough: [:], installing: ["CFFIXED_USER_HOME": "relative"]).isEmpty, "only an absolute home")

    // Idempotent install decisions.
    let a = Data("a".utf8), b = Data("b".utf8)
    check(Plan.installAction(existing: nil, desired: a, loaded: false, serviceRunning: false) == .writeAndLoad, "first install")
    check(Plan.installAction(existing: nil, desired: a, loaded: true, serviceRunning: true) == .replace, "loaded without a file: replace")
    check(Plan.installAction(existing: a, desired: a, loaded: true, serviceRunning: true) == .nothing, "unchanged and running: nothing")
    check(Plan.installAction(existing: a, desired: a, loaded: true, serviceRunning: false) == .restart, "parked or between runs: restart")
    check(Plan.installAction(existing: a, desired: a, loaded: false, serviceRunning: false) == .writeAndLoad, "installed, not loaded: load")
    check(Plan.installAction(existing: b, desired: a, loaded: true, serviceRunning: true) == .replace, "another binary or options: replace")
    check(Plan.installAction(existing: b, desired: a, loaded: false, serviceRunning: true) == .replace, "changed and not loaded: replace")

    let disabled = """
    disabled services = {
        "io.darkbloom.provider" => disabled
        "\(app)" => enabled
        "\(Plan.labelPrefix)aaaaaaaaaaaa" => true
    }
    """
    check(!Plan.isDisabled(label: app, printDisabledOutput: disabled), "enabled is not disabled")
    check(Plan.isDisabled(label: Plan.labelPrefix + "aaaaaaaaaaaa", printDisabledOutput: disabled), "older launchctl: => true")
    check(Plan.isDisabled(label: "io.darkbloom.provider", printDisabledOutput: disabled), "=> disabled")
    check(!Plan.isDisabled(label: "io.darkbloom", printDisabledOutput: disabled), "whole label only")

    // `darkbloom status`.
    let boot = 1_000.0, now = 5_000.0
    check(Plan.statusLines(agents: [], serviceRunning: false, paired: false, supervisor: nil, now: now, bootTime: boot).isEmpty,
          "nothing on a Mac outside a cluster")
    check(Plan.statusLines(agents: [], serviceRunning: false, paired: true, supervisor: nil, now: now, bootTime: boot).first?
          .contains("not running and not set to start at login") == true, "paired, not installed")
    check(Plan.statusLines(agents: [], serviceRunning: true, paired: true, supervisor: nil, now: now, bootTime: boot).first?
          .contains("not set to start at login") == true, "an older detached service")
    var state = ClusterMemberSupervisorState(supervisorPID: 7, version: "v", bootTime: boot, phase: .running,
        budget: ClusterMemberRestartBudget(), current: .init(pid: 8, startedAt: now - 30), runs: 2, updatedAt: now)
    let lines = Plan.statusLines(agents: [(app, true)], serviceRunning: true, paired: true, supervisor: state, now: now, bootTime: boot + 2)
    check(lines.count == 2 && lines[0] == "Cluster service: running; starts at login (launchd \(app))", "installed and running: \(lines)")
    check(lines.last?.hasPrefix("  supervisor: running; member pid 8 up 30 s; runs 2") == true, "supervisor line: \(lines)")
    state.bootTime = boot - 86_400
    check(Plan.statusLines(agents: [(app, true)], serviceRunning: true, paired: true, supervisor: state, now: now, bootTime: boot).count == 1,
          "a supervisor record from an earlier boot is not shown")
    check(Plan.statusLines(agents: [(app, false)], serviceRunning: false, paired: true, supervisor: nil, now: now, bootTime: boot).first?
          .contains("not loaded now") == true, "installed, not loaded")
    check(state.summary(now: now).hasPrefix("cluster member supervisor: "), "the member's own summary is unchanged")
}

print("cluster supervision checks: \(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
