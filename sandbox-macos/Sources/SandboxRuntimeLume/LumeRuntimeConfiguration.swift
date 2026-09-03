import Foundation
import SandboxRuntime

/// What a tenant VM is allowed to reach.
package enum LumeTenantNetworkPolicy: Sendable, Equatable {
    /// No network device at all. Nothing to bring up, nothing to reach, and no
    /// helper process whose death would open a hole.
    case isolated
    /// The guest shares the host's NAT. Correct for building base images, whose
    /// unattended install needs SSH; wrong for tenant code, which would sit on
    /// the provider's LAN.
    case hostNAT

    /// The value `lume run --network` takes.
    package var lumeArgument: String {
        switch self {
        case .isolated:
            return "none"
        case .hostNAT:
            return "nat"
        }
    }

    /// Whether this confines tenant egress to something the host enforces.
    package var confinesEgress: Bool {
        switch self {
        case .isolated:
            return true
        case .hostNAT:
            return false
        }
    }
}

public enum LumeRuntimeTrustPolicy: Sendable {
    case production
    case developmentAdHoc

    /// Whether the pinned Lume had its provenance verified, rather than being
    /// accepted on an ad-hoc signature for local work.
    public var isProvenanceVerified: Bool {
        switch self {
        case .production:
            return true
        case .developmentAdHoc:
            return false
        }
    }
}

package enum LumeGuestCommandPolicy: Sendable {
    case disabled
    case baseImagePreparationAndDevelopment
    /// Tenant workloads. Reachable only once the guest has a per-sandbox
    /// identity and a verified agent, which is what the other two cases were
    /// waiting for.
    case tenantExecution

    /// Whether this policy admits `execute` at all.
    ///
    /// A computed property rather than a `case` match at the call site, so
    /// adding a fourth case is a compile error here instead of a silent
    /// refusal there.
    var permitsGuestCommands: Bool {
        switch self {
        case .disabled:
            return false
        case .baseImagePreparationAndDevelopment, .tenantExecution:
            return true
        }
    }
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
        "2e90fd88fe7c8a379e621162015b7fea249db4d4c560ddfb02fc86461308c011"
    public static let pinnedIsolatedNetworkPatchPath =
        "ThirdParty/lume-patches/0009-isolated-tenant-network.patch"
    public static let pinnedIsolatedNetworkPatchSHA256 =
        "bc0193fa661dd77c161124e4e3be2fce6f9055d5618dfac64f1c9bb99961e09e"
    public static let pinnedPatches = [
        pinnedPatchPath: pinnedPatchSHA256,
        pinnedLivenessPatchPath: pinnedLivenessPatchSHA256,
        pinnedRunLockIdentityPatchPath: pinnedRunLockIdentityPatchSHA256,
        pinnedBrokerLifecyclePatchPath: pinnedBrokerLifecyclePatchSHA256,
        pinnedGuestChannelPatchPath: pinnedGuestChannelPatchSHA256,
        pinnedGuestIdentityPatchPath: pinnedGuestIdentityPatchSHA256,
        pinnedEmergencyStopPatchPath: pinnedEmergencyStopPatchSHA256,
        pinnedGuestAgentPatchPath: pinnedGuestAgentPatchSHA256,
        pinnedIsolatedNetworkPatchPath: pinnedIsolatedNetworkPatchSHA256,
    ]

    public let executable: URL
    public let storageDirectory: URL
    /// Whether a baked agent is installed able to run commands.
    ///
    /// Stated at the call site rather than inferred from another flag: an image
    /// is made executable deliberately, and the daemon that bakes it is the
    /// only thing that knows whether it is building a tenant base image.
    package let bakeExecutableGuestAgent: Bool

    /// The network a started VM gets.
    ///
    /// Defaults to `.hostNAT` because that is what every path did before this
    /// existed, and because base-image preparation genuinely needs it. The
    /// serve path asks for `.isolated`.
    package let tenantNetworkPolicy: LumeTenantNetworkPolicy
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

    /// The policy stays `.disabled` here, and that is not the hardcode it
    /// looks like: `LumeGuestCommandPolicy` is `package`, so this initializer
    /// is the one for callers outside the package, and refusing guest commands
    /// is the only safe answer for a caller that cannot name a policy. Targets
    /// inside the package — `ServeCommand`, `PrepareBaseCommand` — use the
    /// `package` initializer below and say what they want.
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
            guestAgentExecutable: nil,
            bakeExecutableGuestAgent: false,
            tenantNetworkPolicy: .hostNAT
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
        guestAgentExecutable: URL? = nil,
        bakeExecutableGuestAgent: Bool = false,
        tenantNetworkPolicy: LumeTenantNetworkPolicy = .hostNAT
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
        self.bakeExecutableGuestAgent = bakeExecutableGuestAgent
        self.tenantNetworkPolicy = tenantNetworkPolicy
    }
}
