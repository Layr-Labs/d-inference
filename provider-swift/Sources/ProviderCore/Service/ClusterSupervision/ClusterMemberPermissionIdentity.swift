import Foundation
import Security

/// Whether macOS will ask this member's permissions once or again after every
/// build (S18, "permissions approved once"). macOS keys both one-time
/// approvals a cluster member needs on the program's code identity:
///
/// - **Local Network privacy** (macOS 15+): the follower dials the leader over
///   the Thunderbolt link. A process started by launchd is judged by its
///   responsible code (the LaunchAgent's executable; the owner and worker it
///   starts inherit it). The alert can only be shown for an executable inside
///   an app bundle whose Info.plist carries `NSLocalNetworkUsageDescription`,
///   and the approval holds across restarts, reboots and updates only while
///   the identity stays the same: a Developer ID signature with one team.
/// - **Application firewall** (when on): a rank that listens is admitted
///   without an alert when it is Developer-ID signed and "Automatically allow
///   downloaded signed software" is on (the macOS default).
///
/// An ad-hoc build's identity is its bytes, so each new build is a new
/// program to both checks. This type reads the identity (no hashing of the
/// executable, no network, no settings) and says which case applies, so the
/// always-on install and the supervisor's log name the problem instead of a
/// follower that silently cannot dial.
public struct ClusterMemberPermissionIdentity: Equatable, Sendable {
    public enum Signing: String, Equatable, Sendable {
        /// Signed by a "Developer ID Application" certificate.
        case developerID
        /// Signed by another certificate (for example Apple Development).
        case otherCertificate
        /// Ad-hoc signed (the default for `swift build` products).
        case adHoc
        /// No signature at all.
        case unsigned
        /// The signature could not be read.
        case unknown
    }

    public enum Verdict: Equatable, Sendable {
        /// macOS asks once per Mac; restarts, reboots and signed updates keep the approval.
        case askedOnce
        /// Not once: macOS asks again for every new build, or cannot ask at all
        /// (a member started by launchd is then refused the link).
        case perBuild
    }

    public var executablePath: String
    public var signing: Signing
    public var teamIdentifier: String?
    /// The enclosing `.app` bundle, nil when the executable is not inside one.
    public var bundlePath: String?
    public var bundleIdentifier: String?
    public var hasLocalNetworkUsageDescription: Bool

    public init(executablePath: String, signing: Signing, teamIdentifier: String?, bundlePath: String?,
                bundleIdentifier: String?, hasLocalNetworkUsageDescription: Bool) {
        self.executablePath = executablePath
        self.signing = signing
        self.teamIdentifier = teamIdentifier
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        self.hasLocalNetworkUsageDescription = hasLocalNetworkUsageDescription
    }

    public var verdict: Verdict { problems.isEmpty ? .askedOnce : .perBuild }

    /// What stops "asked once", most important first; empty when nothing does.
    public var problems: [String] {
        var problems: [String] = []
        switch signing {
        case .developerID:
            break
        case .adHoc, .unsigned:
            problems.append("this build is \(signing == .adHoc ? "ad-hoc signed" : "unsigned"): macOS treats every new build "
                + "as a new program, so Local Network (and the firewall, on a Mac whose rank listens) ask again after each "
                + "build, and a member started by launchd cannot dial the other Mac until approved")
        case .otherCertificate:
            problems.append("this build is not signed with a Developer ID certificate: the firewall's \"allow downloaded "
                + "signed software\" does not cover it")
        case .unknown:
            problems.append("the code signature of this build could not be read")
        }
        if bundlePath == nil {
            problems.append("the executable is not inside Darkbloom.app: macOS has no app to show the Local Network alert "
                + "for when launchd starts it")
        } else if !hasLocalNetworkUsageDescription {
            problems.append("Darkbloom.app carries no NSLocalNetworkUsageDescription (releases before always-on cluster "
                + "members): macOS cannot ask for Local Network access; update to a release that carries it")
        }
        return problems
    }

    /// Why a cluster service that launchd starts from this build could not
    /// reach the other Mac over the cable, nil when it can. macOS keys the
    /// one-time Local Network approval on a signed app's identity: an ad-hoc,
    /// unsigned or unreadable build, or one outside a Darkbloom.app that
    /// carries `NSLocalNetworkUsageDescription`, has no approval to keep, and
    /// a member launchd starts is refused the link ("may not reach the local
    /// network"). The firewall-only problem of another certificate does not
    /// stop the link. The onboarding uses this to keep the service in the
    /// user's session instead of installing a login agent that cannot serve.
    public var launchdLinkRefusal: String? {
        var reasons: [String] = []
        switch signing {
        case .adHoc: reasons.append("this build is ad-hoc signed")
        case .unsigned: reasons.append("this build is unsigned")
        case .unknown: reasons.append("the code signature of this build could not be read")
        case .developerID, .otherCertificate: break
        }
        if bundlePath == nil {
            reasons.append("the executable is not inside Darkbloom.app")
        } else if !hasLocalNetworkUsageDescription {
            reasons.append("Darkbloom.app carries no NSLocalNetworkUsageDescription")
        }
        guard !reasons.isEmpty else { return nil }
        return reasons.joined(separator: "; ") + ": macOS cannot approve Local Network once for a service launchd starts, "
            + "so it could not reach the other Mac over the cable"
    }

    /// One line for logs and the install command.
    public var summary: String {
        let who = [bundleIdentifier, teamIdentifier.map { "team \($0)" }, signing.rawValue]
            .compactMap { $0 }.joined(separator: ", ")
        switch verdict {
        case .askedOnce:
            return "permissions: asked once (\(who)); approve Local Network on this Mac the first time macOS asks"
        case .perBuild:
            return "permissions: not asked once (\(who)): " + problems.joined(separator: "; ")
        }
    }

    // MARK: - Pure classification

    /// `flags` is the code signature's flag word, `leafCertificateSummary`
    /// the subject summary of the signing certificate, `infoPlist` the
    /// enclosing bundle's Info.plist.
    public static func classify(executablePath: String, signatureReadable: Bool, flags: UInt32?,
                                leafCertificateSummary: String?, teamIdentifier: String?,
                                infoPlist: [String: Any]?) -> ClusterMemberPermissionIdentity {
        let signing: Signing
        if !signatureReadable {
            signing = .unknown
        } else if let flags, flags & adHocFlag != 0 {
            signing = .adHoc
        } else if let leaf = leafCertificateSummary {
            signing = leaf.hasPrefix("Developer ID Application") ? .developerID : .otherCertificate
        } else {
            signing = flags == nil ? .unsigned : .adHoc
        }
        let bundle = enclosingAppBundle(of: executablePath)
        let usage = (infoPlist?["NSLocalNetworkUsageDescription"] as? String).map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? false
        return ClusterMemberPermissionIdentity(
            executablePath: executablePath, signing: signing,
            teamIdentifier: teamIdentifier.flatMap { $0.isEmpty ? nil : $0 },
            bundlePath: bundle, bundleIdentifier: bundle == nil ? nil : infoPlist?["CFBundleIdentifier"] as? String,
            hasLocalNetworkUsageDescription: bundle != nil && usage)
    }

    /// `kSecCodeSignatureAdhoc`.
    static let adHocFlag: UInt32 = 0x0002

    /// `/X/Darkbloom.app/Contents/MacOS/darkbloom` -> `/X/Darkbloom.app`.
    public static func enclosingAppBundle(of executablePath: String) -> String? {
        let components = (executablePath as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 4,
              components[components.count - 2] == "MacOS",
              components[components.count - 3] == "Contents",
              components[components.count - 4].hasSuffix(".app") else { return nil }
        return components.dropLast(3).joined(separator: "/")
    }

    // MARK: - Live

    /// Reads the identity of the executable at `path` (the resolved path the
    /// LaunchAgent records). Reads the signature only; never validates or
    /// hashes the executable.
    public static func current(executablePath path: String) -> ClusterMemberPermissionIdentity {
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        var readable = false
        var flags: UInt32?
        var leaf: String?
        var team: String?
        if SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
           let staticCode {
            let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            if status == errSecSuccess, let dictionary = info as? [String: Any] {
                readable = true
                if dictionary[kSecCodeInfoIdentifier as String] != nil {
                    flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
                }
                team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
                if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
                   let first = certificates.first {
                    leaf = SecCertificateCopySubjectSummary(first) as String?
                }
            }
        }
        let plist = enclosingAppBundle(of: path).flatMap { bundle -> [String: Any]? in
            guard let data = FileManager.default.contents(atPath: bundle + "/Contents/Info.plist") else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        return classify(executablePath: path, signatureReadable: readable, flags: flags,
                        leafCertificateSummary: leaf, teamIdentifier: team, infoPlist: plist)
    }
}
