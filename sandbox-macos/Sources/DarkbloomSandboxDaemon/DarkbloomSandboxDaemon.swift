import Darwin
import Foundation
import SandboxRuntimeVZ

@main
enum DarkbloomSandboxDaemon {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch let error as DaemonCLIError {
            writeError(error.description)
            exit(error.exitCode)
        } catch {
            writeError(String(describing: error))
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else {
            throw DaemonCLIError.usage
        }
        switch command {
        case "doctor":
            try runDoctor(Array(arguments.dropFirst()))
        case "restore-image":
            try await runRestoreImage(Array(arguments.dropFirst()))
        case "prepare-base":
            try await PrepareBaseCommand.run(Array(arguments.dropFirst()))
        case "reconcile-expired":
            try await ReconcileExpiredCommand.run(
                Array(arguments.dropFirst())
            )
        case "version":
            print("darkbloom-sandboxd 0.1.0")
        case "help", "--help", "-h":
            printUsage()
        default:
            throw DaemonCLIError.unknownCommand(command)
        }
    }

    private static func runDoctor(_ arguments: [String]) throws {
        let allowed = Set(["--json", "--development-unsigned"])
        guard arguments.allSatisfy(allowed.contains) else {
            throw DaemonCLIError.invalidArguments("doctor")
        }
        let report = SandboxHostInspector().inspect(policy: SandboxHostInspectionPolicy(
            requireVirtualizationEntitlement: !arguments.contains("--development-unsigned")
        ))
        if arguments.contains("--json") {
            try printJSON(report)
        } else {
            print("Darkbloom macOS sandbox host")
            for check in report.checks {
                print("[\(check.status.rawValue.uppercased())] \(check.id): \(check.summary)")
            }
            print(report.isEligible ? "ELIGIBLE" : "INELIGIBLE")
        }
        guard report.isEligible else {
            throw DaemonCLIError.hostIneligible
        }
    }

    private static func runRestoreImage(_ arguments: [String]) async throws {
        guard arguments.first == "latest" else {
            throw DaemonCLIError.invalidArguments("restore-image")
        }
        let remaining = Array(arguments.dropFirst())
        guard remaining.allSatisfy({ $0 == "--json" }) else {
            throw DaemonCLIError.invalidArguments("restore-image")
        }
        let image = try await MacOSRestoreImageCatalog().latestSupported()
        if remaining.contains("--json") {
            try printJSON(image)
        } else {
            print("URL: \(image.url.absoluteString)")
            print("Build: \(image.buildVersion)")
            print("macOS: \(image.operatingSystemVersion)")
            print("Minimum CPU: \(image.minimumCPUCount)")
            print("Minimum memory bytes: \(image.minimumMemoryBytes)")
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DaemonCLIError.outputEncoding
        }
        print(text)
    }

    private static func printUsage() {
        print(
            """
            Usage:
              darkbloom-sandboxd doctor [--json] [--development-unsigned]
              darkbloom-sandboxd restore-image latest [--json]
              darkbloom-sandboxd prepare-base --lume PATH --storage DIR
                --ipsw FILE --name NAME [--cpu N] [--memory-gib N]
                [--disk-gib N] [--json]
              darkbloom-sandboxd reconcile-expired --lume PATH --storage DIR
                --capacity-dir DIR --max-cpu N --max-memory-gib N
                [--max-growth-gib N] [--storage-headroom-gib N] [--json]
              darkbloom-sandboxd version
            """
        )
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

enum DaemonCLIError: Error, CustomStringConvertible {
    case usage
    case unknownCommand(String)
    case invalidArguments(String)
    case hostIneligible
    case reconciliationIncomplete
    case outputEncoding

    var exitCode: Int32 {
        switch self {
        case .usage, .unknownCommand, .invalidArguments:
            64
        case .hostIneligible:
            78
        case .reconciliationIncomplete:
            75
        case .outputEncoding:
            70
        }
    }

    var description: String {
        switch self {
        case .usage:
            return "missing command; run darkbloom-sandboxd help"
        case .unknownCommand(let command):
            return "unknown command '\(command)'; run darkbloom-sandboxd help"
        case .invalidArguments(let command):
            return "invalid \(command) arguments; run darkbloom-sandboxd help"
        case .hostIneligible:
            return "host is not eligible for macOS sandbox workloads"
        case .reconciliationIncomplete:
            return "one or more expired leases remain fenced for reconciliation"
        case .outputEncoding:
            return "failed to encode command output"
        }
    }
}
