import Darwin
import Foundation
import SandboxRuntime
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
        case AccountlessSystemCommandWorker.command:
            exit(try await AccountlessSystemCommandWorker.run(Array(arguments.dropFirst())))
        case "doctor":
            try runDoctor(Array(arguments.dropFirst()))
        case "restore-image":
            try await runRestoreImage(Array(arguments.dropFirst()))
        case "prepare-base":
            try await PrepareBaseCommand.run(Array(arguments.dropFirst()))
        case "prepare-accountless-base":
            try await SandboxSignalCancellation.run {
                try await AccountlessBaseCommand.run(Array(arguments.dropFirst()))
            }
        case "discard-base":
            try await SandboxSignalCancellation.run {
                try await DiscardBaseCommand.run(Array(arguments.dropFirst()))
            }
        case "reconcile-expired":
            try await ReconcileExpiredCommand.run(
                Array(arguments.dropFirst())
            )
        case "serve":
            do {
                try await SandboxSignalCancellation.run {
                    try await ServeCommand.run(Array(arguments.dropFirst()))
                }
            } catch is CancellationError {
                // Serve has already awaited cleanup. A failed stop proof is a
                // different error and must still produce a nonzero exit.
                return
            }
        case "host-mode":
            try HostModeCommand.run(Array(arguments.dropFirst()))
        case "version":
            print("darkbloom-sandboxd 0.1.0")
        case "help", "--help", "-h":
            printUsage()
        default:
            throw DaemonCLIError.unknownCommand(command)
        }
    }

    private static func runDoctor(_ arguments: [String]) throws {
        let options = try DoctorOptions(arguments)
        let report = SandboxHostInspector().inspect(policy: SandboxHostInspectionPolicy(
            requireVirtualizationEntitlement: !options.developmentUnsigned
        ), storageDirectory: options.storage)
        if options.json {
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
              darkbloom-sandboxd doctor [--storage DIR] [--json] [--development-unsigned]
              darkbloom-sandboxd restore-image latest [--json]
              darkbloom-sandboxd prepare-base --lume PATH --storage DIR
                --ipsw FILE --name NAME [--cpu N] [--memory-gib N]
                [--disk-gib N] [--guest-release PATH] [--json]
              darkbloom-sandboxd prepare-accountless-base PHASE
                --host-identity-file FILE --host-id UUID --storage DIR --name NAME [--json]
                reserve: --lume PATH --ipsw FILE --guest-release DIR [--cpu N] [--memory-gib N]
                payload: --guest-release DIR --output NEW_DIR
                stage: --lume PATH --payload DIR --journal-dir DIR
                authorize-boot: --lume PATH --payload DIR --journal-dir DIR --boot-journal-dir DIR --permit-file FILE
                boot: --permit-file FILE
                collect: --permit-file FILE --boot-journal-dir DIR --collection-dir DIR --collection-file FILE
                abort-collection: --permit-file FILE --boot-journal-dir DIR --collection-dir DIR
                publish-installed: --permit-file FILE --collection-file FILE --guest-release DIR
                qualify: --permit-file FILE --collection-file FILE --guest-release DIR --capacity-dir DIR --qualification-dir DIR
                Reserve, boot, publish-installed and qualify run in the selected GUI session; other phases require root.
                Qualify uses an existing dedicated-host capacity store and one private journal per attempt.
                Repeating an incomplete qualification cleans up and aborts; use a new journal for a fresh attempt.
              darkbloom-sandboxd discard-base --host-identity-file FILE --host-id UUID
                --lume PATH --storage DIR --name NAME --installation-id UUID [--json]
                Run as the selected host user after stopping the broker and settling root maintenance.
                Refuses ready templates; retries complete only the exact installation's pending deletion.
              darkbloom-sandboxd reconcile-expired --lume PATH --storage DIR
                --capacity-dir DIR --max-cpu N --max-memory-gib N
                [--max-growth-gib N] [--storage-headroom-gib N] [--json]
              darkbloom-sandboxd serve --host-identity-file <root-owned.json> --coordinator WSS_URL --host-id UUID
                --token-file FILE --lume PATH --storage DIR --capacity-dir DIR
                --base-images ID[,ID...] --max-cpu N --max-memory-gib N
                [--max-growth-gib N]
                [--storage-headroom-gib N] [--development-ad-hoc-lume]
                [--allow-insecure-loopback] [--guest-release PATH]
              darkbloom-sandboxd host-mode --storage DIR --capacity-dir DIR
                [--mode draining|sandbox_dedicated|inference]
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
    case qualificationIncomplete
    case outputEncoding

    var exitCode: Int32 {
        switch self {
        case .usage, .unknownCommand, .invalidArguments:
            64
        case .hostIneligible:
            78
        case .reconciliationIncomplete, .qualificationIncomplete:
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
        case .qualificationIncomplete:
            return "interrupted qualification was cleaned up; use a new --qualification-dir for a fresh attempt"
        case .outputEncoding:
            return "failed to encode command output"
        }
    }
}
