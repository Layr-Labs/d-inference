import Foundation

/// A local, informational notice shared by every CLI entry path. It never
/// changes command dispatch, serving authorization, or installed profiles.
enum MacOSUpgradeNotice {
    static func message(for version: OperatingSystemVersion) -> String? {
        guard version.majorVersion > 0, version.majorVersion < 27 else { return nil }
        return """
        Warning: This Mac is running macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion). Upgrade to macOS 27 or later.
        Darkbloom MDM will be deactivated soon. macOS 27 supports App Attest without Darkbloom MDM.
        Existing MDM verification remains supported during the transition. Keep your Darkbloom profile installed until `darkbloom unenroll` confirms App Attest migration is ready.
        """
    }

    static func emit(
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        write: (String) -> Void = printError
    ) {
        if let message = message(for: version) { write(message) }
    }
}
