import Darwin

/// POSIX mode bits do not account for macOS extended ACL grants.
enum CacheDirectoryPermissions {
    static func validate(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw CacheStorageError("Cache directory must be owned by you without group or other write permission.")
        }
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            // For an already-open valid directory, Darwin uses ENOENT when
            // there is no extended ACL. Ordinary private directories are safe.
            if errno == ENOENT { return }
            throw CacheStorageError("Cannot inspect cache directory ACL permissions.")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var index = ACL_FIRST_ENTRY
        while acl_get_entry(acl, index.rawValue, &entry) == 0 {
            index = ACL_NEXT_ENTRY
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard let entry, acl_get_tag_type(entry, &tag) == 0,
                  acl_get_permset(entry, &permissions) == 0, let permissions else {
                throw CacheStorageError("Cannot inspect cache directory ACL entry.")
            }
            guard tag == ACL_EXTENDED_ALLOW else { continue }
            // Refuse mutating grants, including inherited grants, even when a
            // preceding deny currently masks one. A fresh private directory
            // needs no extended write grant; harmless read/deny ACLs are fine.
            for permission in [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE,
                               ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES,
                               ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER] {
                let granted = acl_get_perm_np(permissions, permission)
                guard granted == 0 else {
                    throw CacheStorageError("Cache directory has a write-granting ACL. Choose a private directory without extended write grants.")
                }
            }
        }
        // Darwin uses EINVAL to signal the end of the ACL entry list.
        guard errno == EINVAL else {
            throw CacheStorageError("Cannot finish inspecting cache directory ACL permissions.")
        }
    }
}
