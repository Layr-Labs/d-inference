import Foundation

/// The single source of truth for the user-facing instructions to ENABLE the
/// boot-security protections the provider requires. Both `darkbloom doctor` and
/// the `darkbloom start` preflight render these exact strings, so there are no
/// duplicated literals to drift apart.
///
/// The instructions cover updating to macOS 26 (Tahoe) via Software Update and
/// turning the protections fully ON — booting into recoveryOS and using
/// `csrutil enable` / Startup Security Utility's "Full Security" — separately for
/// Apple Silicon and Intel (Apple T2).
public enum BootSecurityGuidance {
    public static let macOSTitle = "How to update to macOS 26 (Tahoe) or later:"
    public static let sipTitle = "How to fully ENABLE System Integrity Protection (SIP):"
    public static let secureBootTitle = "How to set Secure Boot to Full Security:"

    /// Combined guide containing only the requested sections, followed by a
    /// single shared verification footer. The single entry point for both the
    /// `start` preflight and `doctor`, which may need to flag any combination of
    /// protections at once — there is exactly one footer, never a duplicate.
    public static func guide(includeMacOS: Bool, includeSIP: Bool, includeSecureBoot: Bool) -> String {
        var lines: [String] = []
        if includeMacOS {
            lines.append(macOSTitle)
            lines.append(contentsOf: macOSSteps())
        }
        if includeSIP {
            if !lines.isEmpty { lines.append("") }
            lines.append(sipTitle)
            lines.append(contentsOf: sipSteps())
        }
        if includeSecureBoot {
            if !lines.isEmpty { lines.append("") }
            lines.append(secureBootTitle)
            lines.append(contentsOf: secureBootSteps())
        }
        if !lines.isEmpty { lines.append("") }
        lines.append(contentsOf: verifyFooter)
        return join(lines)
    }

    // MARK: - Sections (single source of literals)

    static func macOSSteps() -> [String] {
        [
            "    1. Open the Apple menu (\u{f8ff}) > System Settings.",
            "    2. Go to General > Software Update.",
            "    3. Install the latest macOS (26 \"Tahoe\" or newer) and restart when prompted.",
        ]
    }

    static func sipSteps() -> [String] {
        [
            "  Apple Silicon:",
            "    1. Shut the Mac down completely.",
            "    2. Press and hold the power button until \"Loading startup options\" appears.",
            "    3. Click Options, then Continue. Pick an admin account and enter its password.",
            "    4. From the menu bar, choose Utilities > Terminal.",
            "    5. Run:  csrutil enable",
            "    6. Restart the Mac (Apple menu > Restart).",
            "  Intel:",
            "    1. Restart and immediately hold Command (\u{2318})-R until the Apple logo appears.",
            "    2. From the menu bar, choose Utilities > Terminal.",
            "    3. Run:  csrutil enable",
            "    4. Restart the Mac.",
            "  If 'csrutil status' shows \"enabled (Custom Configuration)\", run 'csrutil clear'",
            "  then 'csrutil enable' in recoveryOS to restore full protection.",
        ]
    }

    static func secureBootSteps() -> [String] {
        [
            "  Apple Silicon:",
            "    1. Shut the Mac down completely.",
            "    2. Press and hold the power button until \"Loading startup options\" appears.",
            "    3. Click Options, then Continue. Pick an admin account and enter its password.",
            "    4. From the menu bar, choose Utilities > Startup Security Utility.",
            "    5. Select your system disk, click \"Security Policy\u{2026}\", choose \"Full Security\", confirm.",
            "    6. Restart the Mac.",
            "  Intel (Apple T2):",
            "    1. Restart and immediately hold Command (\u{2318})-R to enter Recovery.",
            "    2. From the menu bar, choose Utilities > Startup Security Utility and authenticate.",
            "    3. Under \"Secure Boot\", choose \"Full Security\".",
            "    4. Restart the Mac.",
        ]
    }

    static let verifyFooter: [String] = [
        "  After rebooting, re-run 'darkbloom doctor' to confirm macOS is 26+, SIP is",
        "  \"enabled\", and Secure Boot passes. Manual checks: 'sw_vers -productVersion'",
        "  (macOS); 'csrutil status' (SIP); 'system_profiler SPiBridgeDataType'",
        "  (ibridge_secure_boot) is the authoritative Secure Boot level on Apple Silicon",
        "  (Tahoe) and Intel T2.",
    ]

    private static func join(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }
}
