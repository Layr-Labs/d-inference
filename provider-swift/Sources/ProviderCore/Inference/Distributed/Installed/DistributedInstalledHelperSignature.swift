import CryptoKit
import Darwin
import Foundation
import Security

/// A cluster helper the provider launches, by the code-signing identifier the
/// release signs it with (`scripts/sign-cluster-helpers.sh`). The owner is
/// this provider's own executable (`darkbloom cluster worker-owner`), so it
/// carries the provider's own identifier and must be the provider's own image.
struct DistributedInstalledHelper: Sendable, Equatable {
    /// nil for the owner: the running provider's own identifier.
    let identifier: String?

    static let owner = Self(identifier: nil)
    static let worker = Self(identifier: "io.darkbloom.darkbloom-cluster-worker")
    /// The placement tool, installed beside the worker under `plannerName`.
    static let planner = Self(identifier: "io.darkbloom.darkbloom-cluster-plan")
    /// `ClusterPlacementInstallation.toolName`.
    static let plannerName = "darkbloom-cluster-plan"
}

/// The running provider's own code signature, from which the launch
/// requirement of every cluster helper is derived.
///
/// Prompts reach the owner, and the data-plane credential and prompts reach
/// the worker, through plain pipes. Their executables are found by paths a
/// saved setup names, and a setup without a coordinator approval pins them by
/// hashes taken from those same files. A provider signed with a certificate
/// therefore launches a helper only if it is signed with the same leaf
/// certificate and carries that helper's identifier: checked strictly on the
/// file before the spawn, and on the suspended child before anything is
/// written to it (`DistributedInstalledLaunchImage.require`). The owner must
/// moreover be this provider's own image: the kernel's cdhash of the child is
/// the kernel's cdhash of this process. Release and DevNet builds are signed by
/// the same workflow, so both carry their own requirement.
///
/// A build not signed by this project's team (ad hoc: local builds; the test
/// host, which Apple signs, for the provider's unit tests) keeps the launch
/// check of the verified bytes only. Such a build cannot use the Secure
/// Enclave key in the signed keychain group or App Attest, so it never serves
/// other people's prompts. A provider that cannot read its own signature
/// refuses every helper.
enum DistributedInstalledHelperSignature: Sendable, Equatable {
    case signed(Signer)
    case unsigned
    case unavailable

    struct Signer: Sendable, Equatable {
        /// SHA-1 of the leaf certificate, as `certificate leaf = H"…"` compares it.
        let leafSHA1: Data
        let identifier: String
        /// The cdhash of the signer's running image (the kernel's, for this process).
        let cdhash: Data
        let team: String?

        func requirement(_ helper: DistributedInstalledHelper) -> String {
            "anchor apple generic and certificate leaf = H\"\(leaf)\" and identifier \"\(helper.identifier ?? identifier)\""
        }

        /// What the running provider itself must satisfy for its certificate to be used.
        func ownRequirement(team: String) -> String {
            "anchor apple generic and certificate leaf = H\"\(leaf)\" and certificate leaf[subject.OU] = \"\(team)\""
        }

        private var leaf: String { leafSHA1.map { String(format: "%02x", $0) }.joined() }
    }

    /// This process's signature (`own()`). A readable answer is kept for the life of the process; an unreadable
    /// one is not: right after an update installs the app, the bundle can still change for some seconds after the
    /// new service starts, and a read in that window would otherwise refuse every cluster helper until a restart.
    /// Each later read checks the running image against its file again, so nothing weaker is ever accepted.
    static var current: Self { Kept.process.value(own) }

    /// Keeps the first readable signature; reads again while the answer is `.unavailable`.
    final class Kept: @unchecked Sendable {
        static let process = Kept()
        private let lock = NSLock()
        private var kept: DistributedInstalledHelperSignature?

        func value(_ read: () -> DistributedInstalledHelperSignature) -> DistributedInstalledHelperSignature {
            lock.lock()
            defer { lock.unlock() }
            if let kept { return kept }
            let answer = read()
            if answer != .unavailable { kept = answer }
            return answer
        }
    }

    /// Red control stand-in: keeps the first answer, whatever it is (the behaviour of `current` above).
    final class Kept: @unchecked Sendable {
        private let lock = NSLock()
        private var kept: DistributedInstalledHelperSignature?

        func value(_ read: () -> DistributedInstalledHelperSignature) -> DistributedInstalledHelperSignature {
            lock.lock()
            defer { lock.unlock() }
            if let kept { return kept }
            let answer = read()
            kept = answer
            return answer
        }
    }

    /// `SignedReleaseIdentity.teamID`: release and DevNet builds.
    static let releaseTeam = "SLDQ2GJ6TL"

    /// This process's signature; its cdhash is the kernel's for its image. The signature is read from the file
    /// the process was started from, so it must describe the running image (its cdhash, which covers its team and
    /// flags): a file replaced since the start can't make a release fall back to the weaker check. A release's
    /// certificate must moreover be the one that validly signs this process and belong to this project's team.
    static func own() -> Self {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              let running = DistributedInstalledLaunchImage.kernelHash(getpid()) else { return .unavailable }
        let signature = of(unsafeBitCast(code, to: SecStaticCode.self), cdhash: running, describing: running)
        guard case .signed(let signer) = signature else { return signature }
        // Another team's certificate is not a Darkbloom release (the unit-test host, which Apple signs).
        guard signer.team == releaseTeam else { return .unsigned }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(signer.ownRequirement(team: releaseTeam) as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return .unavailable }
        return signature
    }

    /// The signature of the executable at `file`, as if it were the running provider (the provider's own
    /// checks, and tests that stand in a signed executable for it).
    static func file(_ file: URL) -> Self {
        var code: SecStaticCode?, information: CFDictionary?
        guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
              let unique = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return .unavailable }
        return of(code, cdhash: unique)
    }

    /// `describing`: the cdhash the signature read must have (the running image's, for this process).
    static func of(_ code: SecStaticCode, cdhash: Data, describing image: Data? = nil) -> Self {
        var information: CFDictionary?
        let reading = kSecCSSigningInformation | (image == nil ? 0 : kSecCSDynamicInformation)
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: reading), &information) == errSecSuccess,
              let values = information as? [String: Any], cdhash.count == DistributedInstalledCodeDirectory.hashBytes,
              image == nil || values[kSecCodeInfoUnique as String] as? Data == image else {
            return .unavailable
        }
        let flags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        guard let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else {
            return flags & SecCodeSignatureFlags.adhoc.rawValue != 0 ? .unsigned : .unavailable
        }
        guard let identifier = values[kSecCodeInfoIdentifier as String] as? String, (1...255).contains(identifier.utf8.count),
              identifier.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0)
                  || $0 == 0x2e || $0 == 0x2d || $0 == 0x5f }) else {
            return .unavailable
        }
        return .signed(.init(leafSHA1: Data(Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)),
                             identifier: identifier, cdhash: cdhash, team: values[kSecCodeInfoTeamIdentifier as String] as? String))
    }

    /// The check a launcher runs on the `helper` it spawns from `file`. The file is checked here, before the
    /// spawn; the returned check runs on the suspended child, before anything is written to it. `pinned`: the
    /// cdhashes of the verified bytes (`DistributedInstalledFiles.Identity`).
    func verifier(_ helper: DistributedInstalledHelper, file: URL,
                  pinned: Set<Data>) throws -> @Sendable (pid_t) throws -> Void {
        switch self {
        case .unavailable:
            throw ClusterConfigurationError.invalid(Self.unreadable)
        case .unsigned:
            #if DEBUG
            // Debug builds (the provider's unit tests) launch CPU fixtures whose installed executables are
            // scripts, which have no code signature. Release builds refuse those; a signed file is always checked.
            if pinned.isEmpty { return { _ in } }
            #endif
            return try DistributedInstalledLaunchImage.verifier(expected: pinned)
        case .signed(let signer):
            return try Self.signedVerifier(signer, helper, file: file, pinned: pinned)
        }
    }

    /// The owner's check where the launcher did not verify its file (the local rank of a session, the link
    /// follower): a signed provider launches only its own image; a build without a certificate launches it
    /// unchecked, as before.
    func ownerVerifier(_ file: URL) throws -> (@Sendable (pid_t) throws -> Void)? {
        switch self {
        case .unavailable: throw ClusterConfigurationError.invalid(Self.unreadable)
        case .unsigned: return nil
        case .signed(let signer): return try Self.signedVerifier(signer, .owner, file: file, pinned: nil)
        }
    }

    /// The check for a helper the provider starts only to read what it prints (the worker's runtime description,
    /// the placement tool's answers; `DistributedCapabilityProbe.run`): before the spawn, the file must satisfy the
    /// helper's requirement; the returned check runs on the suspended child, which must run that file's image and
    /// satisfy the requirement, before it runs and so before anything it prints is read. nil in a build without this
    /// project's certificate, which starts the helper as before.
    func metadataVerifier(_ helper: DistributedInstalledHelper, file: URL,
                          deadline: UInt64) throws -> (@Sendable (pid_t) throws -> Void)? {
        switch self {
        case .unavailable: throw ClusterConfigurationError.invalid(Self.unreadable)
        case .unsigned: return nil
        case .signed(let signer):
            guard helper != .owner else { throw ClusterConfigurationError.invalid(Self.refusal(helper)) }
            let images = try DistributedInstalledFiles.digest(file, maximumBytes: 256 << 20, executable: true,
                deadline: deadline).identity.codeDirectoryHashes
            return try Self.signedVerifier(signer, helper, file: file, pinned: images)
        }
    }

    /// `darkbloom cluster doctor`: whether this provider would start the owner, worker and placement tool a saved
    /// setup names (nil: not checked, a build without this project's certificate), and what the operator reads.
    func doctor(owner: URL, worker: URL, planner: URL? = nil) -> (passed: Bool?, detail: String) {
        switch self {
        case .unavailable: return (false, Self.unreadable)
        case .unsigned:
            return (nil, "This build has no Developer ID signature; its cluster helpers are checked against their pinned bytes only.")
        case .signed(let signer):
            let helpers = [(DistributedInstalledHelper.owner, owner), (.worker, worker)] + (planner.map { [(.planner, $0)] } ?? [])
            let refusals = helpers.compactMap { helper, file in
                (try? Self.requireFile(signer, helper, file: file, pinned: nil)) == nil ? Self.refusal(helper) : nil
            }
            guard refusals.isEmpty else { return (false, refusals.joined(separator: "; ") + ". The pair is not served until this is fixed.") }
            return (true, planner == nil
                ? "The owner is this Darkbloom's own executable and the worker is signed with its Developer ID."
                : "The owner is this Darkbloom's own executable and the worker and placement tool are signed with its Developer ID.")
        }
    }

    /// `darkbloom cluster doctor`: whether `file` is a cluster worker signed like this provider (its Developer ID and
    /// the worker's identifier, every architecture strictly). False unless this build is signed with this project's
    /// certificate.
    func signsWorker(_ file: URL) -> Bool {
        guard case .signed(let signer) = self else { return false }
        return (try? Self.requireFile(signer, .worker, file: file, pinned: nil)) != nil
    }

    /// Before the spawn: strict validation of every architecture of the file against the requirement, and for the
    /// owner, one of its arm64 images is this provider's running image (`pinned`, or read from the file).
    private static func requireFile(_ signer: Signer, _ helper: DistributedInstalledHelper, file: URL,
                                    pinned: Set<Data>?) throws {
        try requireFile(file, requirement: signer.requirement(helper), helper: helper)
        guard helper == .owner else { return }
        let images = try pinned ?? DistributedInstalledFiles.digest(file, maximumBytes: 256 << 20, executable: true,
            deadline: DispatchTime.now().uptimeNanoseconds + 30_000_000_000).identity.codeDirectoryHashes
        guard images.contains(signer.cdhash) else { throw ClusterConfigurationError.invalid(refusal(helper)) }
    }

    private static func signedVerifier(_ signer: Signer, _ helper: DistributedInstalledHelper, file: URL,
                                       pinned: Set<Data>?) throws -> @Sendable (pid_t) throws -> Void {
        let requirement = signer.requirement(helper)
        try requireFile(signer, helper, file: file, pinned: pinned)
        let expected: Set<Data>
        if helper == .owner {
            expected = [signer.cdhash]
        } else {
            guard let pinned, !pinned.isEmpty else { throw ClusterConfigurationError.invalid(refusal(helper)) }
            expected = pinned
        }
        return { pid in try DistributedInstalledLaunchImage.require(pid: pid, expected: expected, requirement: requirement) }
    }

    /// Strict validation of every architecture of the file, against the requirement.
    private static func requireFile(_ file: URL, requirement text: String, helper: DistributedInstalledHelper) throws {
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                                         requirement) == errSecSuccess else {
            throw ClusterConfigurationError.invalid(refusal(helper))
        }
    }

    static let unreadable = "This Darkbloom could not read its own code signature, so it does not start cluster helpers; reinstall Darkbloom"

    /// What the operator reads (in the start failure and in `darkbloom doctor`); no path or hash.
    static func refusal(_ helper: DistributedInstalledHelper) -> String {
        guard let identifier = helper.identifier else {
            return "The cluster owner this setup names is not this Darkbloom's own signed executable; if Darkbloom was just updated, restart it, otherwise reinstall Darkbloom and run the cluster setup again"
        }
        return "This Mac's cluster helper \(identifier) is not signed by the same Developer ID as this Darkbloom; reinstall Darkbloom"
    }
}
