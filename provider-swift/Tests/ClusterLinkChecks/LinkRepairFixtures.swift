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
    var mode = ClusterLinkRepair.Mode.durable
    var approval: (ClusterLinkPrivilegedRequest, FakeRepairWorld) -> ClusterLinkApprovalResult = { _, _ in .unavailable }
    var machineIdentifier: String? = FakeRepairWorld.machine
    var record = ClusterLinkAliasRecord()
    var recordFailsToLoad = false
    var recordFailsToSave = false
    var onPause: (FakeRepairWorld) -> Void = { _ in }

    private(set) var commands = [ClusterLinkToolCommand]()
    private(set) var approvalRequests = [ClusterLinkPrivilegedRequest]()
    private(set) var recordSaves = 0
    private(set) var pauses = 0

    init(_ tools: FakeLinkTools) { self.tools = tools }

    /// A world whose fixes add the address alone.
    static func temporary(_ tools: FakeLinkTools) -> FakeRepairWorld {
        let world = FakeRepairWorld(tools)
        world.mode = .temporary
        return world
    }

    /// Approval that behaves like the real change on Mac B's `en6`.
    static func applying(_ request: ClusterLinkPrivilegedRequest, _ world: FakeRepairWorld) -> ClusterLinkApprovalResult {
        let address = request.address.dottedDecimal
        switch request.purpose {
        case .addAddress:
            world.giveAddress(address)
        case .keepAddress:
            world.giveAddress(address)
            world.tools.installKeeper(interface: request.interface, address: address)
        case .remove(let remnants):
            // As the commands do: a loaded job goes together with the address it adds.
            if remnants.address || remnants.keeperJob { world.takeAddress() }
            if remnants.keeperJob { world.tools.keeperJobs[request.interface] = nil }
            if remnants.keeperFile { world.tools.keeperJobFiles[request.interface] = nil }
        }
        return .applied
    }

    /// The port gets the address and publishes its GID; the keeper is untouched.
    func giveAddress(_ address: String) {
        tools.interfaces = FakeLinkTools.macBFixed(address: address).interfaces
        tools.details = FakeLinkTools.macBFixed(address: address).details
    }

    /// macOS strips the port again.
    func takeAddress() {
        tools.interfaces = FakeLinkTools.macB.interfaces
        tools.details = FakeLinkTools.macB.details
    }

    var environment: ClusterLinkRepair.Environment {
        .init(
            toolRunner: { [self] in
                { [self] command in
                    commands.append(command)
                    return tools.outcome(of: command)
                }
            },
            requestApproval: { [self] request in
                approvalRequests.append(request)
                return approval(request, self)
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

    func fix(device: String? = nil, dryRun: Bool = false) -> ClusterLinkRepairResult {
        ClusterLinkRepair.fix(device: device, mode: mode, dryRun: dryRun, in: environment)
    }

    func remove(device: String? = nil, dryRun: Bool = false) -> ClusterLinkRepairResult {
        ClusterLinkRepair.remove(device: device, dryRun: dryRun, in: environment)
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
