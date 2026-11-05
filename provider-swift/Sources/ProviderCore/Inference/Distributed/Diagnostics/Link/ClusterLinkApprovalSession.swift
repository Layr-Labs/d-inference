import Foundation
import Security

/// Whether macOS can show its approval prompt to this process. In an SSH session with no desktop it cannot: the
/// prompt `osascript` asks for ends at once with an authorization error (`approvalUnavailable`). The setup and the
/// cable port's removal check it first, so they say where to run instead of failing part way (2026-11-04, owner).
public enum ClusterLinkApprovalSession {
    /// An SSH session (`SSH_CONNECTION` or `SSH_TTY`) whose security session has no window server access.
    public static func cannotPrompt(environment: [String: String] = ProcessInfo.processInfo.environment,
                                    graphicAccess: () -> Bool = hasGraphicAccess) -> Bool {
        (environment["SSH_CONNECTION"] != nil || environment["SSH_TTY"] != nil) && !graphicAccess()
    }

    /// This process's security session can show windows (an Aqua session).
    public static func hasGraphicAccess() -> Bool {
        var attributes = SessionAttributeBits()
        guard SessionGetInfo(callerSecuritySession, nil, &attributes) == errSecSuccess else { return false }
        return attributes.contains(.sessionHasGraphicAccess)
    }

    /// Said before a step that needs the prompt, where none can show: the words of
    /// `ClusterOnboardingDriver.noPromptOverSSHLines`, kept here too because the link's checks build this folder alone.
    public static func lines(command: String) -> [String] {
        ["macOS can't show its approval prompt over SSH.",
         "Run `\(command)` in Terminal on this Mac's own screen, or through Screen Sharing."]
    }
}
