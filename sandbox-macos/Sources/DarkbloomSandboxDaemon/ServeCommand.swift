import Darwin
import Foundation
import SandboxCore
import SandboxHostControl
import SandboxRuntime
import SandboxRuntimeLume
import SandboxRuntimeVZ

enum ServeCommand {
    static func run(_ arguments: [String]) async throws {
        let options = try Options(arguments)
        let report = SandboxHostInspector().inspect(
            policy: SandboxHostInspectionPolicy(
                requireVirtualizationEntitlement:
                    !options.developmentAdHocLume
            )
        )
        guard report.isEligible,
              report.cpuCount >= Int(options.maximumCPUCount),
              report.memoryBytes >= options.maximumMemoryBytes
        else {
            throw DaemonCLIError.hostIneligible
        }

        let policy = try SandboxCapacityPolicy(
            maximumReservedCPUCount: options.maximumCPUCount,
            maximumReservedMemoryBytes: options.maximumMemoryBytes,
            maximumReservedGrowthBytes: options.maximumGrowthBytes,
            storageHeadroomBytes: options.storageHeadroomBytes,
            maximumLeaseDurationSeconds:
                SandboxCapacityPolicy.maximumSupportedLeaseDurationSeconds
        )
        let capacity = try SandboxHostCapacityArbiter(
            stateDirectory: options.capacityDirectory,
            storageDirectory: options.storageDirectory,
            policy: policy
        )
        let initial = try capacity.initialize()
        let runtimeConfiguration = try LumeRuntimeConfiguration(
                executable: options.lumeExecutable,
                storageDirectory: options.storageDirectory,
                commandTimeoutSeconds: 120,
                createTimeoutSeconds: 7_200,
                trustPolicy: options.developmentAdHocLume
                    ? .developmentAdHoc
                    : .production,
                guestCommandPolicy: .tenantExecution,
                // Attach the channel so a tenant VM's baked agent is adopted
                // and its handshake verified. Without a port no device is
                // attached and every command would fall back to SSH.
                guestChannelPort: LumeRuntimeConfiguration
                    .defaultGuestChannelPort,
                // Tenant VMs get no network device. Readiness no longer needs
                // one: a VM whose agent serves commands is proven ready over
                // the channel, so nothing here waits on guest IP discovery.
                tenantNetworkPolicy: .isolated
        )
        let isolationReadiness = SandboxHostIsolationReadiness.derived(
            from: runtimeConfiguration
        )
        let runtime = try LumeLeaseFencedVirtualMachineRuntime(
            configuration: runtimeConfiguration,
            capacityArbiter: capacity
        )
        let reconciliation = try await runtime.reconcileExpiredLeases()
        guard reconciliation.allSatisfy({
            if case .retained = $0.outcome {
                return false
            }
            return true
        }) else {
            throw DaemonCLIError.reconciliationIncomplete
        }
        if initial.mode == .inference {
            _ = try capacity.setMode(.draining)
        }
        if try capacity.snapshot().mode == .draining {
            _ = try capacity.setMode(.sandboxDedicated)
        }

        let adapter = SandboxHostProductionAdapter(
            capacity: capacity,
            runtime: runtime,
            isolationReadiness: isolationReadiness
        )
        if let reason = isolationReadiness.blockingReason {
            // Say it once at startup rather than leaving an operator to work
            // out why a healthy-looking host advertises itself as draining.
            FileHandle.standardError.write(Data(
                "darkbloom-sandboxd: refusing sandbox jobs: \(reason)\n".utf8
            ))
        }
        let capabilities = SandboxWireHostCapabilities(
            daemonVersion: "0.1.0",
            operatingSystem: "macos",
            architecture: report.architecture,
            machineModel: Self.sysctlString("hw.model") ?? "unknown-mac",
            chipName: Self.sysctlString("machdep.cpu.brand_string")
                ?? "unknown-apple-silicon",
            cpuCount: UInt16(report.cpuCount),
            memoryBytes: report.memoryBytes,
            maximumSandboxes: UInt16(
                SandboxCapacityPolicy.supportedRunningSandboxes
            ),
            workspaceSizesBytes: [
                25 * SandboxResourcePolicy.gibibyte,
                50 * SandboxResourcePolicy.gibibyte,
            ],
            baseImageIDs: options.baseImageIDs,
            supportsGPU: false
        )
        let client = SandboxHostControlClient(
            configuration: try SandboxHostControlConfiguration(
                coordinatorURL: options.coordinatorURL,
                hostID: options.hostID,
                token: try SandboxHostTokenFile.read(options.tokenFile),
                capabilities: capabilities,
                allowInsecureLoopback: options.allowInsecureLoopback
            ),
            heartbeatSource: adapter,
            messageHandler: adapter
        )
        try await client.run()
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: bytes)
    }

    struct Options {
        let coordinatorURL: URL
        let hostID: UUID
        let tokenFile: URL
        let lumeExecutable: URL
        let storageDirectory: URL
        let capacityDirectory: URL
        let maximumCPUCount: UInt16
        let maximumMemoryBytes: UInt64
        let maximumGrowthBytes: UInt64
        let storageHeadroomBytes: UInt64
        let baseImageIDs: [String]
        let developmentAdHocLume: Bool
        let allowInsecureLoopback: Bool

        init(_ arguments: [String]) throws {
            var values: [String: String] = [:]
            var developmentAdHocLume = false
            var allowInsecureLoopback = false
            var index = 0
            while index < arguments.count {
                let option = arguments[index]
                switch option {
                case "--development-ad-hoc-lume":
                    guard !developmentAdHocLume else {
                        throw DaemonCLIError.invalidArguments("serve")
                    }
                    developmentAdHocLume = true
                    index += 1
                case "--allow-insecure-loopback":
                    guard !allowInsecureLoopback else {
                        throw DaemonCLIError.invalidArguments("serve")
                    }
                    allowInsecureLoopback = true
                    index += 1
                default:
                    guard Self.valueOptions.contains(option),
                          values[option] == nil,
                          index + 1 < arguments.count
                    else {
                        throw DaemonCLIError.invalidArguments("serve")
                    }
                    values[option] = arguments[index + 1]
                    index += 2
                }
            }

            guard let coordinator = values["--coordinator"],
                  let coordinatorURL = URL(string: coordinator),
                  let hostID = UUID(uuidString: values["--host-id"] ?? ""),
                  let tokenFile = values["--token-file"],
                  let lume = values["--lume"],
                  let storage = values["--storage"],
                  let capacity = values["--capacity-dir"],
                  let encodedBaseImages = values["--base-images"],
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
                  tokenFile.hasPrefix("/"),
                  lume.hasPrefix("/"),
                  storage.hasPrefix("/"),
                  capacity.hasPrefix("/")
            else {
                throw DaemonCLIError.invalidArguments("serve")
            }
            self.coordinatorURL = coordinatorURL
            self.hostID = hostID
            self.tokenFile = URL(fileURLWithPath: tokenFile)
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
            self.maximumMemoryBytes = try Self.gibibytes(maximumMemoryGiB)
            self.maximumGrowthBytes = try Self.gibibytes(maximumGrowthGiB)
            self.storageHeadroomBytes = try Self.gibibytes(
                storageHeadroomGiB
            )
            let baseImageIDs = encodedBaseImages.split(
                separator: ",",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard !baseImageIDs.isEmpty,
                  baseImageIDs.count <= 32,
                  Set(baseImageIDs).count == baseImageIDs.count,
                  baseImageIDs.allSatisfy(
                      SandboxVirtualMachineNamePolicy.isValid
                  )
            else {
                throw DaemonCLIError.invalidArguments("serve")
            }
            self.baseImageIDs = baseImageIDs
            self.developmentAdHocLume = developmentAdHocLume
            self.allowInsecureLoopback = allowInsecureLoopback
        }

        private static func gibibytes(_ value: UInt64) throws -> UInt64 {
            let (bytes, overflow) = value.multipliedReportingOverflow(
                by: SandboxResourcePolicy.gibibyte
            )
            guard !overflow else {
                throw DaemonCLIError.invalidArguments("serve")
            }
            return bytes
        }

        private static let valueOptions: Set<String> = [
            "--coordinator",
            "--host-id",
            "--token-file",
            "--lume",
            "--storage",
            "--capacity-dir",
            "--base-images",
            "--max-cpu",
            "--max-memory-gib",
            "--max-growth-gib",
            "--storage-headroom-gib",
        ]
    }
}

enum SandboxHostTokenFile {
    static func read(_ url: URL) throws -> String {
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let parentDescriptor: Int32
        do {
            parentDescriptor = try SandboxAuthorityFileSystem
                .openPrivateDirectory(
                    at: parent,
                    createIfMissing: false
                )
        } catch {
            throw DaemonCLIError.invalidArguments("serve")
        }
        defer { close(parentDescriptor) }
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw DaemonCLIError.invalidArguments("serve")
        }
        defer { close(descriptor) }
        let data: Data
        do {
            data = try SandboxAuthorityFileSystem.readStablePrivateFile(
                descriptor,
                maximumBytes: 512
            )
        } catch {
            throw DaemonCLIError.invalidArguments("serve")
        }
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw DaemonCLIError.invalidArguments("serve")
        }
        let token = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...256).contains(token.utf8.count),
              !token.contains(where: \.isWhitespace)
        else {
            throw DaemonCLIError.invalidArguments("serve")
        }
        return token
    }
}
