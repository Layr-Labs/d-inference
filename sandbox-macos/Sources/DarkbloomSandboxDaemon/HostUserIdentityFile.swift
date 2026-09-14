import Darwin
import Foundation

enum HostUserIdentityFile {
    static let maximumBytes = 8192

    static func read(_ url: URL) throws -> Data {
        guard url.isFileURL, url.baseURL == nil else { throw HostUserIdentityError.insecureFile }
        var path = url.path
        if path == "/var" || path.hasPrefix("/var/") || path == "/tmp" || path.hasPrefix("/tmp/") {
            path = "/private" + path
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "" else { throw HostUserIdentityError.insecureFile }
        let root = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { throw HostUserIdentityError.insecureFile }
        defer { close(root) }
        return try read(components: Array(parts.dropFirst()), root: root, ownerUID: 0)
    }

    // Tests provide a private fixture root descriptor and owner, never a CLI or
    // environment override. The production entry always starts at root UID 0.
    static func read(components: [String], root: Int32, ownerUID: uid_t,
                     afterRead: () throws -> Void = {}) throws -> Data {
        guard !components.isEmpty, components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
        }) else { throw HostUserIdentityError.insecureFile }
        let parent = try openParent(root, components: components.dropLast(), ownerUID: ownerUID)
        defer { close(parent) }
        let parentIdentity = try metadata(parent)
        let name = components.last!
        let descriptor = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw HostUserIdentityError.insecureFile }
        defer { close(descriptor) }
        let before = try metadata(descriptor)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_uid == ownerUID,
              before.st_mode & 0o7777 == 0o444, before.st_nlink == 1,
              before.st_size > 0, before.st_size <= maximumBytes else { throw HostUserIdentityError.insecureFile }
        try noACL(descriptor)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: maximumBytes + 1)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw HostUserIdentityError.insecureFile }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw HostUserIdentityError.insecureFile }
        }
        try afterRead()
        let currentParent = try openParent(root, components: components.dropLast(), ownerUID: ownerUID)
        defer { close(currentParent) }
        var named = stat()
        guard fstatat(currentParent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              sameIdentity(parentIdentity, try metadata(currentParent)),
              stable(before, try metadata(descriptor)), stable(before, named),
              data.count == before.st_size else { throw HostUserIdentityError.insecureFile }
        return data
    }

    private static func openParent(_ root: Int32, components: ArraySlice<String>, ownerUID: uid_t) throws -> Int32 {
        var current = fcntl(root, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else { throw HostUserIdentityError.insecureFile }
        do {
            try directory(current, ownerUID: ownerUID)
            for name in components {
                let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else { throw HostUserIdentityError.insecureFile }
                do { try directory(next, ownerUID: ownerUID) }
                catch { close(next); throw error }
                close(current); current = next
            }
            return current
        } catch { close(current); throw error }
    }

    private static func directory(_ fd: Int32, ownerUID: uid_t) throws {
        let value = try metadata(fd)
        guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == ownerUID,
              value.st_mode & 0o022 == 0 else { throw HostUserIdentityError.insecureFile }
        try noACL(fd)
    }

    private static func metadata(_ fd: Int32) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw HostUserIdentityError.insecureFile }
        return value
    }

    private static func noACL(_ fd: Int32) throws {
        errno = 0
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl)); throw HostUserIdentityError.insecureFile
        }
        guard errno == ENOENT else { throw HostUserIdentityError.insecureFile }
    }

    private static func sameIdentity(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    private static func stable(_ first: stat, _ second: stat) -> Bool {
        sameIdentity(first, second) && first.st_uid == second.st_uid && first.st_gid == second.st_gid
            && first.st_mode == second.st_mode && first.st_nlink == second.st_nlink && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}
