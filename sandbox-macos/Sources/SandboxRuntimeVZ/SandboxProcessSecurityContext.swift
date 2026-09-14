import Darwin
import SandboxHostContextSupport
import Security

/// A logged-in console user does not establish the caller's security context.
/// In particular, changing BSD credentials leaves an audit/session identity
/// behind and cannot turn a daemon or SSH process into a GUI login agent.
struct SandboxProcessSecurityContextSnapshot: Equatable, Sendable {
    let realUID: UInt32
    let effectiveUID: UInt32
    let sessionStatus: Int32
    let sessionID: UInt32
    let sessionAttributes: UInt32
    let auditStatus: Int32
    let auditUID: UInt32?

    static func capture() -> Self {
        var sessionID: SecuritySessionId = 0
        var attributes = SessionAttributeBits()
        let status = SessionGetInfo(callerSecuritySession, &sessionID, &attributes)
        var auditUID: UInt32 = 0
        let auditStatus = darkbloom_current_audit_user(&auditUID)
        return Self(realUID: getuid(), effectiveUID: geteuid(), sessionStatus: status,
                    sessionID: sessionID, sessionAttributes: attributes.rawValue,
                    auditStatus: auditStatus, auditUID: auditStatus == 0 ? auditUID : nil)
    }

    var isUsableGUISession: Bool {
        realUID > 0 && realUID != UInt32.max && realUID == effectiveUID
            && auditStatus == 0 && auditUID == realUID
            && sessionStatus == errSecSuccess && sessionID != 0 && sessionID != UInt32.max
            && sessionAttributes & SessionAttributeBits.sessionHasGraphicAccess.rawValue != 0
            && sessionAttributes & SessionAttributeBits.sessionIsRoot.rawValue == 0
            && sessionAttributes & SessionAttributeBits.sessionIsRemote.rawValue == 0
    }
}
