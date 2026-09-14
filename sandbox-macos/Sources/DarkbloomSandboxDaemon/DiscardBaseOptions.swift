import Foundation
import SandboxRuntime

struct DiscardBaseOptions {
    let name: String
    let installationID: UUID
    let hostID: UUID
    let storage: URL
    let executable: URL
    let hostIdentityFile: URL
    let json: Bool

    init(_ arguments: [String]) throws {
        let required: Set<String> = ["--name", "--installation-id", "--host-id", "--storage", "--lume", "--host-identity-file"]
        var values: [String: String] = [:], json = false, index = 0
        while index < arguments.count {
            let option = arguments[index]
            if option == "--json" {
                guard !json else { throw Self.invalid }
                json = true; index += 1; continue
            }
            guard required.contains(option), values[option] == nil, index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else { throw Self.invalid }
            values[option] = arguments[index + 1]; index += 2
        }
        guard Set(values.keys) == required,
              let installationID = UUID(uuidString: values["--installation-id"]!),
              let hostID = UUID(uuidString: values["--host-id"]!),
              let name = values["--name"], SandboxVirtualMachineNamePolicy.isValid(name) else { throw Self.invalid }
        self.name = name; self.installationID = installationID; self.hostID = hostID; self.json = json
        storage = try Self.path(values["--storage"]!)
        executable = try Self.path(values["--lume"]!)
        hostIdentityFile = try Self.path(values["--host-identity-file"]!)
    }

    private static func path(_ value: String) throws -> URL {
        guard value.hasPrefix("/"), value != "/", value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              value.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw invalid }
        return URL(fileURLWithPath: value)
    }
    private static var invalid: DaemonCLIError { .invalidArguments("discard-base") }
}
