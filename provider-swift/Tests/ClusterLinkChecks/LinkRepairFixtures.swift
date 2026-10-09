import Foundation

/// A scripted Mac for the fix and remove flows: canned tool results that an
/// "approval" may swap, an in-memory alias record, and a log of everything
/// that was asked. No child process, prompt or file is involved.
final class FakeRepairWorld {
    struct RecordFailure: Error {}

    /// A made-up machine value; the address below is what the derivation
    /// yields for it and `en6`. Neither belongs to a real Mac.
    static let machine = "FIXTURE-MACHINE"
    static let en6Address = "169.254.188.90"

    var tools: FakeLinkTools
    var approval: (ClusterLinkAliasCommand, FakeRepairWorld) -> ClusterLinkApprovalResult = { _, _ in .unavailable }
    var machineIdentifier: String? = FakeRepairWorld.machine
    var record = ClusterLinkAliasRecord()
    var recordFailsToLoad = false
    var recordFailsToSave = false
    var onPause: (FakeRepairWorld) -> Void = { _ in }

    private(set) var commands = [ClusterLinkToolCommand]()
    private(set) var approvalRequests = [ClusterLinkAliasCommand]()
    private(set) var recordSaves = 0
    private(set) var pauses = 0

    init(_ tools: FakeLinkTools) { self.tools = tools }

    /// Approval that behaves like the real change: the port gets the address.
    static func applying(_ command: ClusterLinkAliasCommand, _ world: FakeRepairWorld) -> ClusterLinkApprovalResult {
        switch command.action {
        case .add: world.tools = .macBFixed(address: command.address.dottedDecimal)
        case .remove: world.tools = .macB
        }
        return .applied
    }

    var environment: ClusterLinkRepair.Environment {
        .init(
            toolRunner: { [self] in
                { [self] command in
                    commands.append(command)
                    return tools.outcome(of: command)
                }
            },
            requestApproval: { [self] command in
                approvalRequests.append(command)
                return approval(command, self)
            },
            machineIdentifier: { [self] in machineIdentifier },
            loadRecord: { [self] in
                if recordFailsToLoad { throw RecordFailure() }
                return record
            },
            updateRecord: { [self] change in
                if recordFailsToLoad || recordFailsToSave { throw RecordFailure() }
                recordSaves += 1
                change(&record)
            },
            pause: { [self] in
                pauses += 1
                onPause(self)
            })
    }

    func fix(device: String? = nil) -> ClusterLinkRepairResult {
        ClusterLinkRepair.fix(device: device, in: environment)
    }

    func remove(device: String? = nil) -> ClusterLinkRepairResult {
        ClusterLinkRepair.remove(device: device, in: environment)
    }
}

extension ClusterLinkCheck {
    static func compactJSON(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Text shown to an operator or written as JSON must never carry an
    /// address, whatever the flow did with one internally.
    static func expectNoAddress(_ text: String, _ label: String, line: Int = #line) {
        for (kind, pattern) in ["IPv4 address": #"[0-9]{1,3}(\.[0-9]{1,3}){3}"#,
                                "MAC address": #"[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}"#] {
            expect(text.range(of: pattern, options: .regularExpression) == nil, "\(label) contains no \(kind)", line: line)
        }
    }
}
