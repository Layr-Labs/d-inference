import Foundation
import SandboxCore
import SandboxRuntime
import SandboxRuntimeLume

enum ReconcileExpiredCommand {
    static func run(_ arguments: [String]) async throws {
        let options = try Options(arguments)
        let policy = try SandboxCapacityPolicy(
            maximumReservedCPUCount: options.maximumCPUCount,
            maximumReservedMemoryBytes: try gibibytes(
                options.maximumMemoryGiB
            ),
            maximumReservedGrowthBytes: try gibibytes(
                options.maximumGrowthGiB
            ),
            storageHeadroomBytes: try gibibytes(
                options.storageHeadroomGiB
            )
        )
        let arbiter = try SandboxHostCapacityArbiter(
            stateDirectory: options.capacityDirectory,
            storageDirectory: options.storageDirectory,
            policy: policy
        )
        let runtime = try LumeLeaseFencedVirtualMachineRuntime(
            configuration: try LumeRuntimeConfiguration(
                executable: options.lumeExecutable,
                storageDirectory: options.storageDirectory,
                commandTimeoutSeconds: 120,
                createTimeoutSeconds: 7_200,
                trustPolicy: options.developmentAdHocLume
                    ? .developmentAdHoc
                    : .production
            ),
            capacityArbiter: arbiter
        )
        let report = Report(
            results: try await runtime.reconcileExpiredLeases()
        )
        if options.json {
            try printJSON(report)
        } else {
            print(
                "Expired leases: \(report.results.count); "
                    + "released: \(report.releasedCount); "
                    + "retained: \(report.retainedCount)"
            )
            for result in report.results {
                print(
                    "\(result.sandboxID) \(result.virtualMachineName) "
                        + "\(result.outcome)"
                )
            }
        }
        guard report.retainedCount == 0 else {
            throw DaemonCLIError.reconciliationIncomplete
        }
    }

    private static func gibibytes(_ value: UInt64) throws -> UInt64 {
        let (bytes, overflow) = value.multipliedReportingOverflow(
            by: SandboxResourcePolicy.gibibyte
        )
        guard !overflow else {
            throw DaemonCLIError.invalidArguments("reconcile-expired")
        }
        return bytes
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DaemonCLIError.outputEncoding
        }
        print(text)
    }

    struct Options {
        let lumeExecutable: URL
        let storageDirectory: URL
        let capacityDirectory: URL
        let maximumCPUCount: UInt16
        let maximumMemoryGiB: UInt64
        let maximumGrowthGiB: UInt64
        let storageHeadroomGiB: UInt64
        let developmentAdHocLume: Bool
        let json: Bool

        init(_ arguments: [String]) throws {
            var values: [String: String] = [:]
            var developmentAdHocLume = false
            var json = false
            var index = 0
            while index < arguments.count {
                let option = arguments[index]
                if option == "--development-ad-hoc-lume" {
                    guard !developmentAdHocLume else {
                        throw DaemonCLIError.invalidArguments(
                            "reconcile-expired"
                        )
                    }
                    developmentAdHocLume = true
                    index += 1
                    continue
                }
                if option == "--json" {
                    guard !json else {
                        throw DaemonCLIError.invalidArguments(
                            "reconcile-expired"
                        )
                    }
                    json = true
                    index += 1
                    continue
                }
                guard Self.valueOptions.contains(option),
                      values[option] == nil,
                      index + 1 < arguments.count
                else {
                    throw DaemonCLIError.invalidArguments(
                        "reconcile-expired"
                    )
                }
                values[option] = arguments[index + 1]
                index += 2
            }

            guard let lume = values["--lume"],
                  let storage = values["--storage"],
                  let capacity = values["--capacity-dir"],
                  let maximumCPUCount = UInt16(
                      values["--max-cpu"] ?? ""
                  ),
                  let maximumMemoryGiB = UInt64(
                      values["--max-memory-gib"] ?? ""
                  ),
                  let maximumGrowthGiB = UInt64(
                      values["--max-growth-gib"] ?? "320"
                  ),
                  let storageHeadroomGiB = UInt64(
                      values["--storage-headroom-gib"] ?? "20"
                  ),
                  maximumCPUCount > 0,
                  maximumMemoryGiB > 0,
                  maximumGrowthGiB > 0,
                  storageHeadroomGiB > 0,
                  lume.hasPrefix("/"),
                  storage.hasPrefix("/"),
                  capacity.hasPrefix("/")
            else {
                throw DaemonCLIError.invalidArguments("reconcile-expired")
            }
            self.lumeExecutable = URL(fileURLWithPath: lume)
            self.storageDirectory = URL(
                fileURLWithPath: storage,
                isDirectory: true
            )
            self.capacityDirectory = URL(
                fileURLWithPath: capacity,
                isDirectory: true
            )
            self.maximumCPUCount = maximumCPUCount
            self.maximumMemoryGiB = maximumMemoryGiB
            self.maximumGrowthGiB = maximumGrowthGiB
            self.storageHeadroomGiB = storageHeadroomGiB
            self.developmentAdHocLume = developmentAdHocLume
            self.json = json
        }

        private static let valueOptions: Set<String> = [
            "--lume",
            "--storage",
            "--capacity-dir",
            "--max-cpu",
            "--max-memory-gib",
            "--max-growth-gib",
            "--storage-headroom-gib",
        ]
    }

    struct Report: Encodable, Equatable {
        let results: [Result]

        init(results: [LumeExpiredLeaseReconciliationResult]) {
            self.results = results.map(Result.init)
        }

        var releasedCount: Int {
            results.filter { $0.outcome != "retained" }.count
        }

        var retainedCount: Int {
            results.filter { $0.outcome == "retained" }.count
        }
    }

    struct Result: Encodable, Equatable {
        let sandboxID: String
        let generation: UInt64
        let fencingToken: UInt64
        let virtualMachineName: String
        let outcome: String
        let detail: String?

        init(_ result: LumeExpiredLeaseReconciliationResult) {
            sandboxID = result.lease.scope.sandboxID.description
            generation = result.lease.scope.generation.rawValue
            fencingToken = result.lease.scope.fencingToken.rawValue
            virtualMachineName = result.lease.virtualMachineName
            switch result.outcome {
            case .released:
                outcome = "released"
                detail = nil
            case .alreadyReleased:
                outcome = "already_released"
                detail = nil
            case .retained(let reason):
                outcome = "retained"
                detail = reason
            }
        }
    }
}
