import Foundation
import SandboxCore
import SandboxRuntime

struct AccountlessBaseOptions: Sendable {
    enum Phase: String, Sendable {
        case reserve, payload, stage, authorizeBoot = "authorize-boot", boot, collect
        case abortCollection = "abort-collection", publishInstalled = "publish-installed"
        case qualify
    }
    let phase: Phase
    let storage: URL
    let name: String
    let hostID: UUID
    let hostIdentityFile: URL
    let json: Bool
    private let values: [String: String]

    init(_ arguments: [String]) throws {
        guard let first = arguments.first, let phase = Phase(rawValue: first) else { throw Self.invalid }
        var values: [String: String] = [:], json = false, index = 1
        let allowed = Self.common.union(Self.options[phase]!)
        while index < arguments.count {
            let option = arguments[index]
            if option == "--json" {
                guard !json else { throw Self.invalid }; json = true; index += 1; continue
            }
            guard allowed.contains(option), values[option] == nil, index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else { throw Self.invalid }
            values[option] = arguments[index + 1]; index += 2
        }
        guard Self.required[phase]!.union(Self.common).isSubset(of: Set(values.keys)),
              let hostID = UUID(uuidString: values["--host-id"]!),
              let name = values["--name"], SandboxVirtualMachineNamePolicy.isValid(name) else { throw Self.invalid }
        for key in Self.pathOptions where values[key] != nil { _ = try Self.path(values[key]!) }
        self.phase = phase; self.values = values; self.json = json; self.name = name; self.hostID = hostID
        storage = try Self.path(values["--storage"]!)
        hostIdentityFile = try Self.path(values["--host-identity-file"]!)
        if phase == .reserve { _ = try specification() }
    }

    func path(_ key: String) throws -> URL {
        guard let value = values[key] else { throw Self.invalid }
        return try Self.path(value)
    }

    func specification() throws -> SandboxVirtualMachineSpecification {
        guard phase == .reserve, let cpu = UInt16(values["--cpu"] ?? "4"),
              let memoryGiB = UInt64(values["--memory-gib"] ?? "8") else { throw Self.invalid }
        let (memory, overflow) = memoryGiB.multipliedReportingOverflow(by: SandboxResourcePolicy.gibibyte)
        guard !overflow else { throw Self.invalid }
        let resources = try SandboxResourceSpecification(cpuCount: cpu, memoryBytes: memory,
            workspaceBytes: 25 * SandboxResourcePolicy.gibibyte, commandTimeoutSeconds: 900)
        return try .init(name: name, resources: resources, imageSource: .appleRestore(url: path("--ipsw")),
            diskBytes: SandboxDiskPolicy.alpha.bootDiskBytes.lowerBound)
    }

    private static func path(_ value: String) throws -> URL {
        guard value.hasPrefix("/"), value != "/", value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              value.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw invalid }
        return URL(fileURLWithPath: value)
    }

    private static var invalid: DaemonCLIError { .invalidArguments("prepare-accountless-base") }
    private static let common: Set<String> = ["--storage", "--name", "--host-id", "--host-identity-file"]
    private static let options: [Phase: Set<String>] = [
        .reserve: ["--lume", "--ipsw", "--guest-release", "--cpu", "--memory-gib"],
        .payload: ["--guest-release", "--output"],
        .stage: ["--lume", "--payload", "--journal-dir"],
        .authorizeBoot: ["--lume", "--payload", "--journal-dir", "--boot-journal-dir", "--permit-file"],
        .boot: ["--permit-file"],
        .collect: ["--permit-file", "--boot-journal-dir", "--collection-dir", "--collection-file"],
        .abortCollection: ["--permit-file", "--boot-journal-dir", "--collection-dir"],
        .publishInstalled: ["--permit-file", "--collection-file", "--guest-release"],
        .qualify: ["--permit-file", "--collection-file", "--guest-release", "--capacity-dir", "--qualification-dir"],
    ]
    private static let required: [Phase: Set<String>] = [
        .reserve: ["--lume", "--ipsw", "--guest-release"],
        .payload: ["--guest-release", "--output"],
        .stage: ["--lume", "--payload", "--journal-dir"],
        .authorizeBoot: ["--lume", "--payload", "--journal-dir", "--boot-journal-dir", "--permit-file"],
        .boot: ["--permit-file"],
        .collect: ["--permit-file", "--boot-journal-dir", "--collection-dir", "--collection-file"],
        .abortCollection: ["--permit-file", "--boot-journal-dir", "--collection-dir"],
        .publishInstalled: ["--permit-file", "--collection-file", "--guest-release"],
        .qualify: ["--permit-file", "--collection-file", "--guest-release", "--capacity-dir", "--qualification-dir"],
    ]
    private static let pathOptions: Set<String> = [
        "--storage", "--host-identity-file", "--lume", "--ipsw", "--guest-release", "--output", "--payload", "--journal-dir",
        "--boot-journal-dir", "--permit-file",
        "--collection-dir", "--collection-file",
        "--capacity-dir", "--qualification-dir",
    ]
}
