import Darwin
import Foundation

/// A drive for the add-on's VM images and jobs (`setup --disk`, or the drive
/// the owner picks in setup). Setup checks the two things an owner must set up
/// by hand, APFS and ownership, before it installs anything; the installer
/// checks each disk again by the add-on's full rules before it writes anything.
enum SandboxWorkDisk {
    /// The first add-on release whose installer takes `--disk`.
    static let minimumAddonVersion = "1.2.0"

    /// The volume that holds a path, as `statfs` reports it.
    struct Volume: Equatable, Sendable {
        var mountPoint: String
        var fileSystem: String
        var ignoresOwnership: Bool
        /// Space free for this user (`df`'s Avail) and the volume's size.
        var freeBytes: Int64 = 0
        var volumeBytes: Int64 = 0
        /// A local disk (`MNT_LOCAL`), not a network share.
        var local = true
        var readOnly = false
        /// Hidden from Finder (`MNT_DONTBROWSE`), as Time Machine and system volumes are.
        var hidden = false
    }

    /// Why a drive cannot take the add-on's work yet, in the order setup checks.
    enum Problem: Equatable, Sendable {
        /// `statfs` failed on the path and every parent.
        case unreadable
        /// The path names `/Volumes/<name>`, and no drive is mounted there.
        case notMounted(String)
        case notAPFS
        /// macOS ignores file ownership on the volume; an administrator can turn it on.
        case ownershipOff
    }

    /// `argument` as an absolute path: `~` expanded, a relative path taken
    /// from `directory`. The installer runs in its own directory, so it must
    /// never get a relative path.
    static func absolutePath(_ argument: String,
                             directory: String = FileManager.default.currentDirectoryPath) -> String {
        let expanded = (argument as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (directory as NSString).appendingPathComponent(expanded)
        return (absolute as NSString).standardizingPath
    }

    /// The volume of `path`, or of its nearest existing parent. Nil only when
    /// `statfs` fails.
    static func volume(at path: String) -> Volume? {
        var probe = path
        while probe != "/", !probe.isEmpty, access(probe, F_OK) != 0 {
            probe = (probe as NSString).deletingLastPathComponent
        }
        var info = statfs()
        guard statfs(probe, &info) == 0 else { return nil }
        func text<T>(_ field: inout T) -> String {
            withUnsafePointer(to: &field) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
            }
        }
        func flag(_ mask: Int32) -> Bool { info.f_flags & UInt32(mask) != 0 }
        let blockSize = Int64(info.f_bsize)
        return Volume(mountPoint: text(&info.f_mntonname), fileSystem: text(&info.f_fstypename),
                      ignoresOwnership: flag(MNT_IGNORE_OWNERSHIP),
                      freeBytes: Int64(clamping: info.f_bavail) * blockSize,
                      volumeBytes: Int64(clamping: info.f_blocks) * blockSize,
                      local: flag(MNT_LOCAL), readOnly: flag(MNT_RDONLY), hidden: flag(MNT_DONTBROWSE))
    }

    /// What keeps `path` (on `volume`) from taking the add-on's work, if anything.
    static func problem(path: String, volume: Volume?) -> Problem? {
        guard let volume else { return .unreadable }
        let components = path.split(separator: "/")
        if components.count >= 2, components[0] == "Volumes" {
            let mount = "/Volumes/\(components[1])"
            guard volume.mountPoint == mount || volume.mountPoint.hasPrefix(mount + "/") else {
                return .notMounted(mount)
            }
        }
        guard volume.fileSystem == "apfs" else { return .notAPFS }
        return volume.ignoresOwnership ? .ownershipOff : nil
    }

    /// One `Work disk` line: a pass, or a failure with the exact fix. Setup
    /// never formats a drive.
    static func check(path: String, volume: Volume?) -> SandboxEligibility.Check {
        func refuse(_ detail: String, fix: String) -> SandboxEligibility.Check {
            SandboxEligibility.Check(level: .fail, name: "Work disk", detail: detail, fix: fix)
        }
        let unreadable = refuse("\(path) cannot be read", fix: "check the path, then run setup again")
        guard let volume else { return unreadable }
        switch problem(path: path, volume: volume) {
        case .unreadable:
            return unreadable
        case .notMounted(let mount):
            return refuse("\(mount) is not a mounted drive",
                          fix: "connect the drive and check that it shows in Finder, then run setup again")
        case .notAPFS:
            return refuse("\(volume.mountPoint) is \(volume.fileSystem), not APFS",
                          fix: "copy off what you keep, erase the drive as APFS in Disk Utility (this deletes "
                              + "everything on it), then run setup again")
        case .ownershipOff:
            return refuse("\(volume.mountPoint) ignores file ownership; turning it on needs an administrator",
                          fix: enableOwnershipCommand(volume.mountPoint))
        case nil:
            let location = volume.mountPoint == path ? path : "\(path) (on \(volume.mountPoint))"
            return SandboxEligibility.Check(level: .pass, name: "Work disk", detail: "\(location): APFS, ownership on")
        }
    }

    /// `sudo diskutil enableOwnership <mount>`, the mount point as one shell word.
    static func enableOwnershipCommand(_ mountPoint: String) -> String {
        "sudo diskutil enableOwnership \(shellWord(mountPoint))"
    }

    /// Runs `sudo diskutil enableOwnership <mount>` on this terminal, so sudo
    /// asks for the password itself; the CLI never reads it. False when it
    /// did not exit 0, or when there is no terminal to ask on.
    static func enableOwnership(mountPoint: String) -> Bool {
        runInForeground("/usr/bin/sudo", ["--", "/usr/sbin/diskutil", "enableOwnership", mountPoint]) == 0
    }

    /// Runs `executable` in this process's group, attached to the terminal,
    /// and returns its exit status. Foundation's `Process` would start it in a
    /// group of its own, outside the terminal's foreground job, where sudo's
    /// password prompt stops on SIGTTIN. Nil without a terminal in the
    /// foreground, when it cannot start, or when a signal ends it.
    static func runInForeground(_ executable: String, _ arguments: [String]) -> Int32? {
        guard isatty(STDIN_FILENO) != 0, tcgetpgrp(STDIN_FILENO) == getpgrp() else { return nil }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the terminal is inherited, not the CLI's other files or sockets.
        guard posix_spawn_file_actions_addinherit_np(&actions, STDIN_FILENO) == 0,
              posix_spawn_file_actions_addinherit_np(&actions, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { return nil }
        let strings = ([executable] + arguments).map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { return nil }
        var argv = strings + [nil]
        var pid: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, executable, &actions, &attributes, buffer.baseAddress!, environ)
        }
        guard spawned == 0 else { return nil }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            guard errno == EINTR else { return nil }
        }
        guard status & 0x7f == 0 else { return nil }
        return (status >> 8) & 0xff
    }

    // MARK: - Drives to offer

    /// The free space a drive needs to be offered: its floor (a tenth of the
    /// drive, 50 to 100 GiB) plus the first Linux job and its images, the
    /// least the add-on places on a disk.
    static func minimumFreeBytes(volumeBytes: Int64) -> Int64 {
        SandboxEligibility.freeSpaceFloor(volumeBytes: volumeBytes) + SandboxEligibility.linuxImagesBytes
            + SandboxEligibility.linuxSlotBytes
    }

    /// The drives setup offers when the owner gives no `--disk`: each volume
    /// mounted at its own `/Volumes/<name>` that shows in Finder, local,
    /// writable and APFS, with room for a job. A drive with ownership off is
    /// offered too: setup can turn it on. Sorted by name.
    static func candidates(volumesDirectory: String = "/Volumes",
                           inspect: (String) -> Volume? = SandboxWorkDisk.volume(at:)) -> [Volume] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: volumesDirectory)) ?? []
        return names.sorted().compactMap { name -> Volume? in
            let mount = volumesDirectory + "/" + name
            // The startup disk's link (`Macintosh HD` → `/`) has another mount point.
            guard !name.hasPrefix("."), let found = inspect(mount), found.mountPoint == mount, found.local,
                  !found.readOnly, !found.hidden, found.fileSystem == "apfs",
                  found.freeBytes >= minimumFreeBytes(volumeBytes: found.volumeBytes) else { return nil }
            return found
        }
    }

    /// `text` as one shell word, quoted only when it needs it.
    static func shellWord(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+:@%")
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(plain.contains) else {
            return "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }
        return text
    }
}
