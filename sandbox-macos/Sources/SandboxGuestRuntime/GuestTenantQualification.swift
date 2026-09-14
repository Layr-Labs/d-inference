import Darwin
import Foundation
import SandboxGuestProtocol

/// Observes only this process's restricted credentials, fixed protected paths,
/// guest disk access and interfaces. It writes no file and reads no secret.
public enum GuestTenantQualification {
    public static let command = GuestQualificationProtocol.command

    public static func run() throws -> Data {
        var virtualized: Int32 = 0, length = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_vmm_present", &virtualized, &length, nil, 0) == 0 else { throw GuestProtocolError.invalidConfiguration }
        let count = getgroups(0, nil)
        guard (0...32).contains(count) else { throw GuestProtocolError.invalidConfiguration }
        var groups = [gid_t](repeating: 0, count: Int(count))
        guard getgroups(count, &groups) == count else { throw GuestProtocolError.invalidConfiguration }
        try Credentials(uid: getuid(), effectiveUID: geteuid(), gid: getgid(), effectiveGID: getegid(),
            groups: groups, virtualized: virtualized).validate()
        try GuestNumericIdentity.validate()
        try requireLegacyTenantNameAbsent()
        guard setuid(0) == -1, getuid() == GuestNumericIdentity.uid, geteuid() == GuestNumericIdentity.uid else {
            throw GuestProtocolError.invalidConfiguration
        }
        try requireDenied("/private/var/db/darkbloom-sandbox/instance.json", flags: O_RDONLY)
        try requireDenied("/private/var/db/darkbloom-sandbox/control/instance.json", flags: O_RDONLY)
        try requireDenied(GuestQualificationProtocol.executable, flags: O_WRONLY)
        let entries = try FileManager.default.contentsOfDirectory(atPath: "/dev")
        guard entries.count <= 4096 else { throw GuestProtocolError.invalidConfiguration }
        let disks = entries.filter(isDiskName)
        guard (6...256).contains(disks.count) else { throw GuestProtocolError.invalidConfiguration }
        for name in disks {
            let path = "/dev/" + name
            var info = stat()
            guard lstat(path, &info) == 0, [S_IFCHR, S_IFBLK].contains(info.st_mode & S_IFMT) else {
                throw GuestProtocolError.invalidConfiguration
            }
            try requireDenied(path, flags: O_RDONLY)
        }
        try requireNoNetworkAddresses()
        return GuestQualificationProtocol.successOutput
    }

    struct Credentials {
        let uid: uid_t; let effectiveUID: uid_t; let gid: gid_t; let effectiveGID: gid_t
        let groups: [gid_t]; let virtualized: Int32
        func validate() throws {
            guard virtualized == 1, uid == GuestNumericIdentity.uid, effectiveUID == uid,
                  gid == GuestNumericIdentity.gid, effectiveGID == gid,
                  groups.count <= 32, groups.allSatisfy({ $0 == GuestNumericIdentity.gid }) else {
                throw GuestProtocolError.invalidConfiguration
            }
        }
    }

    static func isDiskName(_ name: String) -> Bool {
        let value = name.hasPrefix("r") ? String(name.dropFirst()) : name
        guard value.hasPrefix("disk"), let first = value.dropFirst(4).utf8.first,
              (48...57).contains(first) else { return false }
        return value.dropFirst(4).utf8.allSatisfy { (48...57).contains($0) || $0 == 115 }
    }

    static func permissionDenied(_ error: Int32) -> Bool { error == EACCES || error == EPERM }

    private static func requireDenied(_ path: String, flags: Int32) throws {
        let descriptor = open(path, flags | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor >= 0 { close(descriptor); throw GuestProtocolError.invalidConfiguration }
        guard permissionDenied(errno) else { throw GuestProtocolError.invalidConfiguration }
    }

    private static func requireLegacyTenantNameAbsent() throws {
        var bytes = [CChar](repeating: 0, count: GuestNumericIdentity.maximumBufferBytes)
        var entry = passwd(), result: UnsafeMutablePointer<passwd>?
        guard getpwnam_r("darkbloomtenant", &entry, &bytes, bytes.count, &result) == 0, result == nil else {
            throw GuestProtocolError.invalidConfiguration
        }
    }

    private static func requireNoNetworkAddresses() throws {
        var entries: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&entries) == 0 else { throw GuestProtocolError.invalidConfiguration }
        defer { if let entries { freeifaddrs(entries) } }
        var current = entries, count = 0
        while let item = current {
            count += 1
            guard count <= 256 else { throw GuestProtocolError.invalidConfiguration }
            if let address = item.pointee.ifa_addr,
               item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
               [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family) {
                throw GuestProtocolError.invalidConfiguration
            }
            current = item.pointee.ifa_next
        }
    }
}
