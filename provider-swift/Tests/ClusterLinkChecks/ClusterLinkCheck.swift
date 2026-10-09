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
            ("alias command", aliasCommand),
            ("approval results", approvalResults),
            ("topology text", topologyText),
            ("fix gating", fixGating),
            ("fix outcomes", fixOutcomes),
            ("remove outcomes", removeOutcomes),
            ("repair vocabulary", repairVocabulary),
            ("alias record file", aliasRecordFile),
            ("watch reducer", watchReducer),
            ("setup flow", setupFlow),
        ]
        for (_, group) in groups { group() }
        guard failures.isEmpty else {
            for failure in failures { print("FAILED \(failure)") }
            print("Cluster link: \(failures.count) of \(passed + failures.count) expectations failed in \(groups.count) groups")
            exit(1)
        }
        print("Cluster link: \(passed) expectations in \(groups.count) groups passed; real children were /bin and /usr/bin fixtures only")
    }
}
