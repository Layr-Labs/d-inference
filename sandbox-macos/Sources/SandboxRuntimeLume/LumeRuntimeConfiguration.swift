import Foundation
import SandboxRuntime

public struct LumeRuntimeConfiguration: Sendable {
    public static let pinnedRepository = "https://github.com/trycua/cua.git"
    public static let pinnedCommit = "737dc2a069528abadee67526d138a907e1c52061"
    public static let pinnedSourcePath = "libs/lume"
    public static let pinnedVersion = "0.5.3"

    public let executable: URL
    public let storageDirectory: URL
    public let commandTimeoutSeconds: UInt32
    public let createTimeoutSeconds: UInt32

    public init(
        executable: URL,
        storageDirectory: URL,
        commandTimeoutSeconds: UInt32 = 60,
        createTimeoutSeconds: UInt32 = 7_200
    ) throws {
        guard executable.isFileURL,
              executable.baseURL == nil,
              storageDirectory.isFileURL,
              storageDirectory.baseURL == nil,
              storageDirectory.path.hasPrefix("/"),
              commandTimeoutSeconds > 0,
              createTimeoutSeconds >= commandTimeoutSeconds
        else {
            throw SandboxRuntimeError.unsupported(
                "Lume configuration requires absolute paths and positive timeouts"
            )
        }
        self.executable = executable
            .standardizedFileURL
            .resolvingSymlinksInPath()
        self.storageDirectory = storageDirectory.standardizedFileURL
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.createTimeoutSeconds = createTimeoutSeconds
    }
}
