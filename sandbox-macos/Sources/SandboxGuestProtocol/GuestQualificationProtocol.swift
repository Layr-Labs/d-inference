import Foundation

/// A fixed unprivileged command in the signed guest binary. It uses ordinary
/// authenticated execution; it introduces no privileged RPC operation.
public enum GuestQualificationProtocol {
    public static let executable = "/usr/local/libexec/darkbloom-sandbox-guest"
    public static let command = "qualify-tenant"
    public static let successOutput = Data("darkbloom-tenant-qualification-v1\n".utf8)
}
