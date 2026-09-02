import Foundation
import SandboxRuntime

public enum LumeRuntimeTrustPolicy: Sendable {
    case production
    case developmentAdHoc
}

package enum LumeGuestCommandPolicy: Sendable {
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
        "189c2b7f3e0adde5966e15e7403ed7657cedfff60208102590e0eac6b524f3b7"
    public static let pinnedBrokerLifecyclePatchPath =
        "ThirdParty/lume-patches/0004-broker-lifecycle-capability.patch"
    public static let pinnedBrokerLifecyclePatchSHA256 =
        "622b7ccee3a2d842e8aad83fe26ce4e1ab4027bd585a10ffddc40d416e288026"
    public static let pinnedGuestChannelPatchPath =
        "ThirdParty/lume-patches/0005-guest-vsock-channel.patch"
    public static let pinnedGuestChannelPatchSHA256 =
        "7716c2a1274844be620a563a9d4fafef4a346a371b5d89817e06d2ae97b2bbc2"
    public static let pinnedGuestIdentityPatchPath =
        "ThirdParty/lume-patches/0006-per-sandbox-guest-identity.patch"
    public static let pinnedGuestIdentityPatchSHA256 =
        "734e53135fe591c77da613807239f40dbe22d97326bc52894b7eba222d24b6ac"
    public static let pinnedEmergencyStopPatchPath =
        "ThirdParty/lume-patches/0007-fix-emergency-stop-state-guard.patch"
    public static let pinnedEmergencyStopPatchSHA256 =
        "04261009b77bb05b402c24361398de80ee2611530789a4d21b432b4f3823b736"
    public static let pinnedGuestAgentPatchPath =
        "ThirdParty/lume-patches/0008-bake-guest-agent.patch"
    public static let pinnedGuestAgentPatchSHA256 =
        "87e62a02ec66ec7e08573495d6e5cefb9d9df4d5fee88235a3a0cab102a9938b"
    public static let pinnedPatches = [
        pinnedPatchPath: pinnedPatchSHA256,
        pinnedLivenessPatchPath: pinnedLivenessPatchSHA256,
        pinnedRunLockIdentityPatchPath: pinnedRunLockIdentityPatchSHA256,
        pinnedBrokerLifecyclePatchPath: pinnedBrokerLifecyclePatchSHA256,
        pinnedGuestChannelPatchPath: pinnedGuestChannelPatchSHA256,
        pinnedGuestIdentityPatchPath: pinnedGuestIdentityPatchSHA256,
        pinnedEmergencyStopPatchPath: pinnedEmergencyStopPatchSHA256,
        pinnedGuestAgentPatchPath: pinnedGuestAgentPatchSHA256,
    ]

    public let executable: URL
    public let storageDirectory: URL
    public let commandTimeoutSeconds: UInt32
    public let createTimeoutSeconds: UInt32
    public let trustPolicy: LumeRuntimeTrustPolicy
    package let guestCommandPolicy: LumeGuestCommandPolicy
    /// Guest vsock port the signed agent listens on, or `nil` to run without a
    /// guest channel. Attaching the device is opt-in so an ordinary run keeps
    /// exactly the device set it had before.
    package let guestChannelPort: UInt32?

    /// Guest agent executable to bake into a freshly installed base image, or
    /// `nil` to install none.
    ///
    /// Only meaningful when creating from a restore image. A clone inherits
    /// the template's disk, so it inherits the template's agent — baking is a
    /// once-per-base-image cost, not a per-sandbox one.
    package let guestAgentExecutable: URL?

    /// Port the baked agent binds and the host connects to. One constant so
    /// the two halves cannot drift apart.
    package static let defaultGuestChannelPort: UInt32 = 8_888

    /// Environment variables patch 0005 reads inside `lume run`.
    public static let guestChannelDescriptorEnvironmentVariable =
        "DARKBLOOM_LUME_GUEST_CHANNEL_FD"
    public static let guestChannelPortEnvironmentVariable =
        "DARKBLOOM_LUME_GUEST_CHANNEL_PORT"

    public init(
        executable: URL,
        storageDirectory: URL,
        commandTimeoutSeconds: UInt32 = 60,
        createTimeoutSeconds: UInt32 = 7_200,
        trustPolicy: LumeRuntimeTrustPolicy = .production
    ) throws {
        try self.init(
            executable: executable,
            storageDirectory: storageDirectory,
            commandTimeoutSeconds: commandTimeoutSeconds,
            createTimeoutSeconds: createTimeoutSeconds,
            trustPolicy: trustPolicy,
            guestCommandPolicy: .disabled,
            guestChannelPort: nil,
            guestAgentExecutable: nil
        )
    }

    package init(
        executable: URL,
        storageDirectory: URL,
        commandTimeoutSeconds: UInt32 = 60,
        createTimeoutSeconds: UInt32 = 7_200,
        trustPolicy: LumeRuntimeTrustPolicy = .production,
        guestCommandPolicy: LumeGuestCommandPolicy,
        guestChannelPort: UInt32? = nil,
        guestAgentExecutable: URL? = nil
    ) throws {
        guard executable.isFileURL,
              executable.baseURL == nil,
              storageDirectory.isFileURL,
              storageDirectory.baseURL == nil,
              storageDirectory.path.hasPrefix("/"),
              commandTimeoutSeconds > 0,
              createTimeoutSeconds >= commandTimeoutSeconds,
              guestChannelPort.map({ $0 > 0 }) ?? true,
              guestAgentExecutable.map({
                  $0.isFileURL
                      && FileManager.default.isReadableFile(atPath: $0.path)
              }) ?? true
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
        self.guestChannelPort = guestChannelPort
        self.guestAgentExecutable = guestAgentExecutable?
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }
}
