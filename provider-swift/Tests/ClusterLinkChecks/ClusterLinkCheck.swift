import Foundation
import Darwin

/// Records every expectation instead of stopping at the first failure, so one
/// run shows the whole state of the link-readiness module.
@main @MainActor enum ClusterLinkCheck {
    static var passed = 0
    static var failures = [String]()

    static func expect(_ condition: Bool, _ message: String, line: Int = #line) {
        if condition { passed += 1 } else { failures.append("line \(line): \(message)") }
    }

    static func expectEqual<Value: Equatable>(_ actual: Value, _ expected: Value, _ message: String, line: Int = #line) {
        expect(actual == expected, "\(message): got \(actual), expected \(expected)", line: line)
    }

    static func main() {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(60); defer { alarm(0) }
        let groups: [(String, () -> Void)] = [
            ("rdma_ctl status text", controlStateText),
            ("no prompt over SSH", noPromptOverSSH),
            ("ibv_devinfo device list text", deviceListText),
            ("ibv_devinfo device detail text", deviceDetailText),
            ("ifconfig text", interfaceText),
            ("command set", commandSet),
            ("Mac A report", macAReport),
            ("Mac B report", macBReport),
            ("machine-level states", machineStates),
            ("port states", portStates),
            ("tool failures", toolFailures),
            ("several active ports", severalActivePorts),
            ("state vocabulary and guidance", stateVocabulary),
            ("names-only output", namesOnlyOutput),
            ("operator summary", operatorSummary),
            ("bounded child process", boundedChildProcess),
            ("link-local address", linkLocalAddress),
            ("address keeper", addressKeeper),
            ("privileged requests", privilegedRequests),
            ("approval results", approvalResults),
            ("topology text", topologyText),
            ("fix gating", fixGating),
            ("fix outcomes", fixOutcomes),
            ("remove outcomes", removeOutcomes),
            ("durable fix outcomes", durableFixOutcomes),
            ("dry runs", dryRuns),
            ("fix remnants", fixRemnants),
            ("repair vocabulary", repairVocabulary),
            ("alias record file", aliasRecordFile),
            ("watch reducer", watchReducer),
            ("setup flow", setupFlow),
            ("setup flow modes", setupFlowModes),
            ("setup flow, onboarding wording", setupFlowPlain),
            ("assigned address", assignedAddressReport),
            ("isolation tool text", isolationToolText),
            ("isolation address", isolationAddress),
            ("isolation command set", isolationCommandSet),
            ("isolation Mac A findings", isolationMacAFindings),
            ("isolation Mac B findings", isolationMacBFindings),
            ("isolation after pairing", isolationPairedMacs),
            ("isolation plans", isolationPlans),
            ("isolation fix outcomes", isolationFixOutcomes),
            ("isolation remove outcomes", isolationRemoveOutcomes),
            ("isolation remove every port", isolationRemoveEveryPort),
            ("isolation last service stops on a failed commit", isolationLastServiceStopsOnFailedCommit),
            ("isolation manual commands run as the script", isolationManualCommandsRunAsTheScript),
            ("isolation record file", isolationRecordFile),
            ("isolation setup flow", isolationSetupFlow),
            ("isolation vocabulary", isolationVocabulary),
            ("launch readiness", launchReadiness),
        ]
        for (_, group) in groups { group() }
        guard failures.isEmpty else {
            for failure in failures { print("FAILED \(failure)") }
            print("Cluster link: \(failures.count) of \(passed + failures.count) expectations failed in \(groups.count) groups")
            exit(1)
        }
        print("Cluster link: \(passed) expectations in \(groups.count) groups passed; real children were /bin and /usr/bin fixtures only")
    }

    /// SSH with no desktop: no prompt can show, said before anything is tried (2026-11-04, owner).
    static func noPromptOverSSH() {
        typealias S = ClusterLinkApprovalSession
        expect(S.cannotPrompt(environment: ["SSH_CONNECTION": "10.0.0.2 50000 10.0.0.1 22"], graphicAccess: { false }), "SSH, no desktop")
        expect(S.cannotPrompt(environment: ["SSH_TTY": "/dev/ttys001"], graphicAccess: { false }), "SSH_TTY alone")
        expect(!S.cannotPrompt(environment: ["SSH_TTY": "/dev/ttys001"], graphicAccess: { true }), "SSH inside a desktop session")
        expect(!S.cannotPrompt(environment: [:], graphicAccess: { false }), "not SSH: macOS decides")
        expect(S.lines(command: "darkbloom cluster link --remove") == ["macOS can't show its approval prompt over SSH.",
            "Run `darkbloom cluster link --remove` in Terminal on this Mac's own screen, or through Screen Sharing."], "the words")
    }
}
