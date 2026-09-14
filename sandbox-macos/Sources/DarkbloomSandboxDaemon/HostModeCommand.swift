import Foundation
import HostRuntimeCoordination
import SandboxRuntime

/// Explicit local operator transition. Readiness is still enforced separately
/// by the signed runtime, guest agent, storage policy, and coordinator admission.
enum HostModeCommand {
    static func run(_ arguments: [String]) throws {
        let options = try Options(arguments)
        let capacity = try SandboxHostCapacityArbiter.openExisting(
            stateDirectory: options.capacityDirectory, storageDirectory: options.storageDirectory)
        var ownership: HostRuntimeLease?
        defer { withExtendedLifetime(ownership) {} }
        if let mode = options.mode, mode != .draining {
            ownership = try HostRuntimeAuthority.system.acquireSandbox()
        }
        let snapshot: SandboxCapacitySnapshot
        if let mode = options.mode { snapshot = try capacity.setMode(mode) }
        else { snapshot = try capacity.snapshot() }
        let report = Report(mode: snapshot.mode.rawValue, activeLeases: snapshot.leases.count,
                            policyRevision: snapshot.policyRevision, nextFencingToken: snapshot.nextFencingToken)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }

    private struct Report: Encodable {
        let mode: String
        let activeLeases: Int
        let policyRevision: UInt64
        let nextFencingToken: UInt64
    }

    struct Options {
        let capacityDirectory: URL
        let storageDirectory: URL
        let mode: SandboxHostMode?

        init(_ arguments: [String]) throws {
            var values: [String: String] = [:]
            guard arguments.count.isMultiple(of: 2) else { throw DaemonCLIError.invalidArguments("host-mode") }
            for index in stride(from: 0, to: arguments.count, by: 2) {
                let key = arguments[index]
                guard ["--capacity-dir", "--storage", "--mode"].contains(key), values[key] == nil else {
                    throw DaemonCLIError.invalidArguments("host-mode")
                }
                values[key] = arguments[index + 1]
            }
            guard let capacity = values["--capacity-dir"], let storage = values["--storage"],
                  capacity.hasPrefix("/"), storage.hasPrefix("/"),
                  URL(fileURLWithPath: capacity).standardizedFileURL.path == capacity,
                  URL(fileURLWithPath: storage).standardizedFileURL.path == storage else {
                throw DaemonCLIError.invalidArguments("host-mode")
            }
            capacityDirectory = URL(fileURLWithPath: capacity)
            storageDirectory = URL(fileURLWithPath: storage)
            if let encoded = values["--mode"] {
                guard let parsed = SandboxHostMode(rawValue: encoded) else { throw DaemonCLIError.invalidArguments("host-mode") }
                mode = parsed
            } else { mode = nil }
        }
    }
}
