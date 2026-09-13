import Foundation
import SandboxGuestProtocol
import SandboxRuntime

/// Only fixed bootstrap stage/reason codes reach operator diagnostics. Never
/// format arbitrary errors, arguments, file contents or configuration values.
public struct GuestBootstrapDiagnostic: Error, Sendable {
    enum Stage: String, Sendable {
        case virtualizedRoot = "virtualized_root"
        case guestIdentity = "guest_identity"
        case workspaceMountpoint = "workspace_mountpoint"
        case numericIdentity = "numeric_identity"
    }

    private let stage: Stage
    private let reason: String
    private let systemError: Int32?

    public var code: String {
        let suffix = systemError.map { " errno=\($0)" } ?? ""
        return "guest_bootstrap.\(stage.rawValue).\(reason)" + suffix
    }

    static func run<T>(_ stage: Stage, _ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch { throw classify(error, stage: stage) }
    }

    private static func classify(_ error: Error, stage: Stage) -> GuestBootstrapDiagnostic {
        if let diagnostic = error as? GuestBootstrapDiagnostic { return diagnostic }
        let reason: String
        var systemError: Int32?
        if let identity = error as? GuestNumericIdentityError {
            switch identity {
            case .userRegistered: reason = "user_registered"
            case .groupRegistered: reason = "group_registered"
            case .lookupFailed(let code): reason = "lookup_failed"; systemError = code
            case .lookupExceedsBound: reason = "lookup_exceeds_bound"
            }
        } else if let filesystem = error as? SandboxAuthorityFileSystemError {
            switch filesystem {
            case .unsafePath: reason = "unsafe_authority"
            case .io(let value): reason = "filesystem_io"; systemError = value
            case .publicationUncertain(let value): reason = "publication_uncertain"; systemError = value
            }
        } else if error is GuestProtocolError {
            reason = "policy_mismatch"
        } else if error is CancellationError {
            reason = "cancelled"
        } else if error is SandboxRuntimeError {
            reason = "subprocess_unavailable"
        } else {
            reason = "unavailable"
        }
        return GuestBootstrapDiagnostic(stage: stage, reason: reason,
                                        systemError: systemError.flatMap { $0 > 0 ? $0 : nil })
    }
}
