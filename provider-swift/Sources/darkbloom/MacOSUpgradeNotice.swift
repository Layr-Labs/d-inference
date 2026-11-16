import Foundation
import ProviderCore

/// A local, informational notice shared by every CLI entry path. It never
/// changes command dispatch, serving authorization, or installed profiles.
enum MacOSUpgradeNotice {
    static func message(for version: OperatingSystemVersion) -> String? {
        guard version.majorVersion > 0, version.majorVersion < 27 else { return nil }
        return """
        Warning: This Mac is running macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) and cannot serve.
        \(ProviderOnboardingPolicy.appAttestRequirement) \(ProviderOnboardingPolicy.upgradeGuidance)
        """
    }

    static func emit(
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        write: (String) -> Void = printError
    ) {
        if let message = message(for: version) { write(message) }
    }
}
