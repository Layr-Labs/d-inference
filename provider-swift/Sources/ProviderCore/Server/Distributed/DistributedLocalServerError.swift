import Foundation

/// Errors of the distributed local server lifecycle. Split verbatim from PR
/// 1226's DistributedLocalServerSession.swift (head 78397f4c) so the staged
/// HTTP response primitives compile without the LocalServer slice; the
/// session/server files land with the product CLI slice (15b-iii).
public enum DistributedLocalServerError: Error, Sendable {
    case alreadyStarted, startupInterrupted, bindFailed, bindTimedOut, lifetimeExpired
    case replacementIdentityChanged, replacementNotPrepared, replacementNotReleased
}
