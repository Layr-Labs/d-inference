import Foundation
import SandboxCore
import SandboxRuntime
import SandboxRuntimeLume

enum PrepareBaseCommand {
    static func run(_ arguments: [String]) async throws {
        let parsed = try Options(arguments)
        let resources = try SandboxResourceSpecification(
            cpuCount: parsed.cpuCount,
            memoryBytes: try gibibytes(parsed.memoryGiB),
            workspaceBytes: 25 * SandboxResourcePolicy.gibibyte,
            commandTimeoutSeconds: 900
        )
        let specification = try SandboxVirtualMachineSpecification(
            name: parsed.name,
            resources: resources,
            imageSource: .restoreImage(
                url: parsed.restoreImage,
                unattendedPreset: "tahoe"
            ),
            diskBytes: try gibibytes(parsed.diskGiB)
        )
        let runtime = LumeVirtualMachineRuntime(configuration: try LumeRuntimeConfiguration(
            executable: parsed.lumeExecutable,
            storageDirectory: parsed.storageDirectory,
            commandTimeoutSeconds: 120,
            createTimeoutSeconds: 7_200
        ))
        let report = try await MacOSBaseImagePreparer(runtime: runtime).prepare(
            specification: specification
        )
        if parsed.json {
            try printJSON(report)
        } else {
            print("Prepared \(report.name)")
            print("Runtime: lume \(report.runtimeVersion)")
            print("Guest: macOS \(report.guestOperatingSystemVersion) \(report.guestArchitecture)")
            print("CPU: \(report.cpuCount)")
            print("Memory bytes: \(report.memoryBytes)")
            print("Disk bytes: \(report.diskBytes)")
        }
    }

    private static func gibibytes(_ value: UInt64) throws -> UInt64 {
        let (bytes, overflow) = value.multipliedReportingOverflow(
            by: SandboxResourcePolicy.gibibyte
        )
        guard !overflow else {
            throw DaemonCLIError.invalidArguments("prepare-base")
        }
        return bytes
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DaemonCLIError.outputEncoding
        }
        print(text)
    }

    struct Options {
        let lumeExecutable: URL
        let storageDirectory: URL
        let restoreImage: URL
        let name: String
        let cpuCount: UInt16
        let memoryGiB: UInt64
        let diskGiB: UInt64
        let json: Bool

        init(_ arguments: [String]) throws {
            var values: [String: String] = [:]
            var json = false
            var index = 0
            while index < arguments.count {
                let option = arguments[index]
                if option == "--json" {
                    guard !json else {
                        throw DaemonCLIError.invalidArguments("prepare-base")
                    }
                    json = true
                    index += 1
                    continue
                }
                guard Self.valueOptions.contains(option),
                      values[option] == nil,
                      index + 1 < arguments.count
                else {
                    throw DaemonCLIError.invalidArguments("prepare-base")
                }
                values[option] = arguments[index + 1]
                index += 2
            }

            guard let lume = values["--lume"],
                  let storage = values["--storage"],
                  let ipsw = values["--ipsw"],
                  let name = values["--name"],
                  let cpu = UInt16(values["--cpu"] ?? "4"),
                  let memory = UInt64(values["--memory-gib"] ?? "8"),
                  let disk = UInt64(values["--disk-gib"] ?? "100"),
                  lume.hasPrefix("/"),
                  storage.hasPrefix("/"),
                  ipsw.hasPrefix("/")
            else {
                throw DaemonCLIError.invalidArguments("prepare-base")
            }
            self.lumeExecutable = URL(fileURLWithPath: lume)
            self.storageDirectory = URL(fileURLWithPath: storage, isDirectory: true)
            self.restoreImage = URL(fileURLWithPath: ipsw)
            self.name = name
            self.cpuCount = cpu
            self.memoryGiB = memory
            self.diskGiB = disk
            self.json = json
        }

        private static let valueOptions: Set<String> = [
            "--lume",
            "--storage",
            "--ipsw",
            "--name",
            "--cpu",
            "--memory-gib",
            "--disk-gib",
        ]
    }
}
