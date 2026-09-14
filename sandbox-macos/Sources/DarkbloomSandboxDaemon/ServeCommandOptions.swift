import Foundation
import SandboxCore
import SandboxRuntime

extension ServeCommand {
    struct Options {
        let coordinatorURL: URL
        let hostID: UUID
        let tokenFile: URL
        let hostIdentityFile: URL
        let lumeExecutable: URL
        let storageDirectory: URL
        let capacityDirectory: URL
        let maximumCPUCount: UInt16
        let maximumMemoryBytes: UInt64
        let maximumGrowthBytes: UInt64
        let storageHeadroomBytes: UInt64
        let baseImageIDs: [String]
        let guestRelease: URL?
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
                  let identityFile = values["--host-identity-file"],
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
                  identityFile.hasPrefix("/"),
                  !identityFile.contains("\0"),
                  !identityFile.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                    .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  lume.hasPrefix("/"),
                  storage.hasPrefix("/"),
                  capacity.hasPrefix("/")
            else {
                throw DaemonCLIError.invalidArguments("serve")
            }
            self.coordinatorURL = coordinatorURL
            self.hostID = hostID
            self.tokenFile = URL(fileURLWithPath: tokenFile)
            self.hostIdentityFile = URL(fileURLWithPath: identityFile)
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
            if let path = values["--guest-release"] {
                guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path else {
                    throw DaemonCLIError.invalidArguments("serve")
                }
                self.guestRelease = URL(fileURLWithPath: path)
            } else {
                self.guestRelease = nil
            }
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
            "--host-identity-file",
            "--lume",
            "--storage",
            "--capacity-dir",
            "--base-images",
            "--max-cpu",
            "--max-memory-gib",
            "--max-growth-gib",
            "--storage-headroom-gib",
            "--guest-release",
        ]
    }
}
