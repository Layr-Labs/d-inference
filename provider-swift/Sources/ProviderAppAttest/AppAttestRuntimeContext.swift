import Darwin
import Foundation
import Security

/// Closed launch-context diagnostic: only the caller's security-session
/// graphic-access bit is reported, never a user, session ID or path.
public enum AppAttestLaunchSession: String, Codable, Sendable, Equatable {
    case gui, background, unknown
}

/// Process context sent on `ready` replies. Diagnostic only: it never enters
/// the client-data hash or any authorization decision.
public struct AppAttestRuntimeContext: Sendable, Equatable {
    public var launchSession: AppAttestLaunchSession
    /// `kern.boottime` in Unix seconds; nil when the sysctl fails.
    public var bootTime: Int64?

    public init(launchSession: AppAttestLaunchSession, bootTime: Int64?) {
        self.launchSession = launchSession
        self.bootTime = bootTime
    }

    public static func current() -> AppAttestRuntimeContext {
        var session = SecuritySessionId()
        var attributes = SessionAttributeBits()
        let status = SessionGetInfo(callerSecuritySession, &session, &attributes)
        return AppAttestRuntimeContext(
            launchSession: launchSession(status: status, attributes: attributes),
            bootTime: systemBootTime())
    }

    static func launchSession(status: OSStatus, attributes: SessionAttributeBits) -> AppAttestLaunchSession {
        guard status == errSecSuccess else { return .unknown }
        return attributes.contains(.sessionHasGraphicAccess) ? .gui : .background
    }

    static func systemBootTime() -> Int64? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0,
              size == MemoryLayout<timeval>.size, value.tv_sec > 0 else { return nil }
        return Int64(value.tv_sec)
    }
}
