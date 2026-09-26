import Foundation
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
        if within(home + "/.darkbloom") { return .userInstall }
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
