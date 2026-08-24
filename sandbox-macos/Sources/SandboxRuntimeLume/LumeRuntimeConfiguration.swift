import Foundation
import SandboxRuntime

public enum LumeRuntimeTrustPolicy: Sendable {
    case production
    case developmentAdHoc
}

public enum LumeGuestCommandPolicy: Sendable {
    case disabled
    case baseImagePreparationAndDevelopment
}

public struct LumeRuntimeConfiguration: Sendable {
    public static let pinnedRepository = "https://github.com/trycua/cua.git"
    public static let pinnedCommit = "737dc2a069528abadee67526d138a907e1c52061"
    public static let pinnedSourcePath = "libs/lume"
    public static let pinnedVersion = "0.5.3"
    public static let pinnedPatchPath =
        "ThirdParty/lume-patches/0001-bound-ssh-command-output.patch"
    public static let pinnedPatchSHA256 =
        "4d10399041b64a60ebde176009ffff761235cc1e70013b7e1549a2c79a34a430"
    public static let pinnedLivenessPatchPath =
        "ThirdParty/lume-patches/0002-fail-closed-run-lock-liveness.patch"
    public static let pinnedLivenessPatchSHA256 =
        "135c94920e4a773b13f1e057e0198a82ffa2d8b1cced0cd23782da84a3ba788a"
    public static let pinnedRunLockIdentityPatchPath =
        "ThirdParty/lume-patches/0003-bind-run-lock-identity.patch"
    public static let pinnedRunLockIdentityPatchSHA256 =
        "0c0a57fb61990c93fdb541183c4555d25c84e2fb218f32149b3891e41e437a17"
    public static let pinnedPatches = [
        pinnedPatchPath: pinnedPatchSHA256,
        pinnedLivenessPatchPath: pinnedLivenessPatchSHA256,
        pinnedRunLockIdentityPatchPath: pinnedRunLockIdentityPatchSHA256,
    ]

    public let executable: URL
    public let storageDirectory: URL
    public let commandTimeoutSeconds: UInt32
    public let createTimeoutSeconds: UInt32
    public let trustPolicy: LumeRuntimeTrustPolicy
    public let guestCommandPolicy: LumeGuestCommandPolicy

    public init(
        executable: URL,
        storageDirectory: URL,
        commandTimeoutSeconds: UInt32 = 60,
        createTimeoutSeconds: UInt32 = 7_200,
        trustPolicy: LumeRuntimeTrustPolicy = .production,
        guestCommandPolicy: LumeGuestCommandPolicy = .disabled
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
        self.trustPolicy = trustPolicy
        self.guestCommandPolicy = guestCommandPolicy
    }
}
