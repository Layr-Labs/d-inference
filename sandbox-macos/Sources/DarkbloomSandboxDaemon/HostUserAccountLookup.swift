import Darwin
import Foundation
import SandboxHostContextSupport

struct HostUserAccountRecord: Equatable, Sendable {
    let name: String
    let uid: UInt32
    let gid: UInt32
    let home: String
    let shell: String
}

enum HostUserAccountLookup {
    struct Result {
        let status: Int32
        let record: HostUserAccountRecord?
    }

    static func lookup(_ identity: HostUserIdentity) throws -> HostUserIdentity {
        let byID = try bounded { buffer in
            var record = passwd(), result: UnsafeMutablePointer<passwd>?
            let status = getpwuid_r(identity.uid, &record, buffer.baseAddress!, buffer.count, &result)
            return Result(status: status, record: status == 0 && result != nil ? copy(record) : nil)
        }
        let byName = try bounded { buffer in
            var record = passwd(), result: UnsafeMutablePointer<passwd>?
            let status = getpwnam_r(identity.recordName, &record, buffer.baseAddress!, buffer.count, &result)
            return Result(status: status, record: status == 0 && result != nil ? copy(record) : nil)
        }
        guard byID == byName, byID.uid == identity.uid, byID.gid == identity.primaryGID,
              byID.name == identity.recordName, byID.home == identity.homeDirectory,
              byID.shell.hasPrefix("/"), !["false", "nologin", "true"].contains(URL(fileURLWithPath: byID.shell).lastPathComponent)
        else { throw HostUserIdentityError.identityMismatch }
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = darkbloom_user_generated_uuid(identity.uid, &bytes)
        guard status == 0 else { throw HostUserIdentityError.lookupUnavailable(status) }
        let value = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return HostUserIdentity(recordName: byID.name, uid: byID.uid, primaryGID: byID.gid,
                               generatedUID: value.uuidString, homeDirectory: byID.home)
    }

    // Bounded reentrant storage; neither NSS lookup reads password hashes.
    // Directory-service availability is distinct from actual Aqua eligibility.
    static func bounded(_ query: (UnsafeMutableBufferPointer<CChar>) -> Result) throws -> HostUserAccountRecord {
        var count = 16 * 1024
        while count <= 1024 * 1024 {
            var bytes = [CChar](repeating: 0, count: count)
            let result = bytes.withUnsafeMutableBufferPointer { query($0) }
            if result.status == 0 {
                guard let record = result.record else { throw HostUserIdentityError.identityMismatch }
                return record
            }
            guard result.status == ERANGE else { throw HostUserIdentityError.lookupUnavailable(result.status) }
            count *= 2
        }
        throw HostUserIdentityError.lookupUnavailable(ERANGE)
    }

    private static func copy(_ record: passwd) -> HostUserAccountRecord? {
        guard let name = record.pw_name, let home = record.pw_dir, let shell = record.pw_shell,
              let name = String(validatingCString: name), let home = String(validatingCString: home),
              let shell = String(validatingCString: shell) else { return nil }
        return HostUserAccountRecord(name: name, uid: record.pw_uid, gid: record.pw_gid, home: home, shell: shell)
    }

    static func requireOwnedHome(_ identity: HostUserIdentity) throws {
        var path = identity.homeDirectory
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") { path = "/private" + path }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first == "", components.count > 1,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") })
        else { throw HostUserIdentityError.identityMismatch }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw HostUserIdentityError.identityMismatch }
        defer { close(descriptor) }
        for part in components.dropFirst() {
            let next = openat(descriptor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw HostUserIdentityError.identityMismatch }
            close(descriptor); descriptor = next
            var info = stat()
            guard fstat(descriptor, &info) == 0, [0, identity.uid].contains(info.st_uid), info.st_mode & 0o022 == 0
            else { throw HostUserIdentityError.identityMismatch }
        }
        var home = stat()
        guard fstat(descriptor, &home) == 0, home.st_uid == identity.uid else { throw HostUserIdentityError.identityMismatch }
    }
}
