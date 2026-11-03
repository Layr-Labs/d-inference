import Foundation
import ProviderBuildEnvironment
import Security

/// Reads the running code's signing information once per call. Shared by the
/// availability check and the `preflight` diagnostic so both see the same
/// entitlements.
enum AppAttestSigningInfo {
    static func current() -> [String: Any]? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return info as? [String: Any]
    }
}

extension AppAttestPreflight {
    /// Live probe of this process: entitlements, embedded provisioning profile
    /// (decoded locally, no network) and a closed bundle-location class.
    public static func current(now: Date = Date()) -> AppAttestPreflight {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let profileURL = bundle.appendingPathComponent("Contents/embedded.provisionprofile")
        let signing = AppAttestSigningInfo.current()
        return build(
            entitlements: signing.map { $0[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:] },
            profile: FileManager.default.contents(atPath: profileURL.path),
            bundlePath: bundle.path,
            home: FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path,
            now: now)
    }

    /// Pure builder. `entitlements` nil means signing info was unavailable
    /// (both entitlement members are then omitted); an empty dictionary means
    /// signed without entitlements.
    static func build(entitlements: [String: Any]?, profile: Data?, bundlePath: String?, home: String, now: Date) -> AppAttestPreflight {
        var preflight = AppAttestPreflight()
        if let entitlements {
            let optIn = entitlements[AppAttestEntitlementPolicy.optIn]
            preflight.optInEntitlement = (optIn as? String) == "CDhash" || (optIn as? [String])?.contains("CDhash") == true
            preflight.environmentEntitlement = environmentClass(entitlements[AppAttestEntitlementPolicy.environment])
        }
        if bundlePath != nil {
            preflight.profilePresent = profile != nil
            if let profile, let expiry = ProvisioningProfileDecoder.expirationDate(profile) {
                preflight.profileExpired = expiry < now
            }
        }
        preflight.bundlePathClass = bundlePath.map { pathClass($0, home: home) }
        return preflight
    }

    static func environmentClass(_ value: Any?) -> EnvironmentEntitlement {
        guard let value else { return .absent }
        switch value as? String {
        case "production": return .production
        case "development": return .development
        default: return .invalid
        }
    }

    static func pathClass(_ path: String, home: String) -> BundlePathClass {
        func within(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        if within(home + "/" + BuildEnvironment.current.installDirectoryName) { return .userInstall }
        if within("/Applications") || within(home + "/Applications") { return .applications }
        return .other
    }
}

/// Extracts `ExpirationDate` from a CMS-signed provisioning profile. The
/// signature is not evaluated: this is a local diagnostic, not trust.
enum ProvisioningProfileDecoder {
    static func expirationDate(_ data: Data) -> Date? {
        guard let plist = content(data),
              let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        else { return nil }
        return object["ExpirationDate"] as? Date
    }

    private static func content(_ data: Data) -> Data? {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let updated = data.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, base, buffer.count)
        }
        guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return nil }
        return content as Data
    }
}

/// Local root-cause evidence for `is_supported_false`. It compares the App
/// Attest entitlements the kernel gave this process at launch with the ones in
/// the code on disk, which is all the `preflight` diagnostic can see, and
/// records how the executable's modification time relates to the process start.
/// It goes to the local provider log only; it is never sent and never changes
/// a decision.
public struct AppAttestEntitlementEvidence: Sendable, Equatable {
    /// Nil when the running task's entitlements could not be read.
    public var runtimeOptIn: Bool?
    public var runtimeEnvironment: AppAttestPreflight.EnvironmentEntitlement?
    /// Nil when signing information for the code on disk was unavailable.
    public var diskOptIn: Bool?
    public var diskEnvironment: AppAttestPreflight.EnvironmentEntitlement?
    /// Executable modification time minus process start, whole seconds. A
    /// positive value means the file changed after this process started (an
    /// in-place exec of a replaced binary keeps the earlier start time).
    public var executableModifiedMinusStartSeconds: Int?

    /// `runtime` reads one entitlement of the running task; nil from the
    /// reader means it is absent. `runtime` itself nil means the task was unavailable.
    static func build(runtime: ((String) -> Any?)?, diskEntitlements: [String: Any]?,
                      executableModifiedAt: Date?, processStartedAt: Date?) -> AppAttestEntitlementEvidence {
        func optIn(_ value: Any?) -> Bool {
            (value as? String) == "CDhash" || (value as? [String])?.contains("CDhash") == true
        }
        var evidence = AppAttestEntitlementEvidence()
        if let runtime {
            evidence.runtimeOptIn = optIn(runtime(AppAttestEntitlementPolicy.optIn))
            evidence.runtimeEnvironment = AppAttestPreflight.environmentClass(runtime(AppAttestEntitlementPolicy.environment))
        }
        if let diskEntitlements {
            evidence.diskOptIn = optIn(diskEntitlements[AppAttestEntitlementPolicy.optIn])
            evidence.diskEnvironment = AppAttestPreflight.environmentClass(diskEntitlements[AppAttestEntitlementPolicy.environment])
        }
        if let executableModifiedAt, let processStartedAt {
            let delta = executableModifiedAt.timeIntervalSince(processStartedAt)
            if delta.isFinite { evidence.executableModifiedMinusStartSeconds = Int(delta.rounded()) }
        }
        return evidence
    }

    /// Live probe of this process. `processStartedAt` is the kernel start time.
    public static func current(processStartedAt: Date?) -> AppAttestEntitlementEvidence {
        let task = SecTaskCreateFromSelf(nil)
        let runtime: ((String) -> Any?)? = task.map { task in
            { key in SecTaskCopyValueForEntitlement(task, key as CFString, nil) }
        }
        let disk = AppAttestSigningInfo.current()
            .map { $0[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:] }
        let modified = Bundle.main.executableURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
        }
        return build(runtime: runtime, diskEntitlements: disk, executableModifiedAt: modified,
                     processStartedAt: processStartedAt)
    }

    /// One log line of closed values: `context` and `startReason` name the
    /// moment; `unavailable` marks a value that could not be read.
    public func line(context: String, startReason: AppAttestStartReason?) -> String {
        func show(_ value: Bool?) -> String { value.map { $0 ? "true" : "false" } ?? "unavailable" }
        return "App Attest entitlement evidence (\(context)): start_reason=\(startReason?.rawValue ?? "unknown")"
            + " runtime_opt_in=\(show(runtimeOptIn)) runtime_environment=\(runtimeEnvironment?.rawValue ?? "unavailable")"
            + " disk_opt_in=\(show(diskOptIn)) disk_environment=\(diskEnvironment?.rawValue ?? "unavailable")"
            + " executable_modified_minus_start_s=\(executableModifiedMinusStartSeconds.map(String.init) ?? "unavailable")"
    }
}
