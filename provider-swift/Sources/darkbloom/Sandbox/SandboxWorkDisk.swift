import Darwin
import Foundation

/// A drive the owner gives with `setup --disk`, for the add-on's VM images and
/// jobs. Setup checks the two things an owner must set up by hand, APFS and
/// ownership, before it downloads anything; the installer checks each disk
/// again by the add-on's full rules before it writes anything.
enum SandboxWorkDisk {
    /// The first add-on release whose installer takes `--disk`.
    static let minimumAddonVersion = "1.2.0"

    /// The volume that holds a path, as `statfs` reports it.
    struct Volume: Equatable, Sendable {
        var mountPoint: String
        var fileSystem: String
        var ignoresOwnership: Bool
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
        return Volume(mountPoint: text(&info.f_mntonname), fileSystem: text(&info.f_fstypename),
                      ignoresOwnership: info.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) != 0)
    }

    /// One `Work disk` line: a pass, or a failure with the exact fix. Setup
    /// never formats a drive or runs `sudo`: the owner runs the fix.
    static func check(path: String, volume: Volume?) -> SandboxEligibility.Check {
        func refuse(_ detail: String, fix: String) -> SandboxEligibility.Check {
            SandboxEligibility.Check(level: .fail, name: "Work disk", detail: detail, fix: fix)
        }
        guard let volume else {
            return refuse("\(path) cannot be read", fix: "check the path, then run setup again")
        }
        let components = path.split(separator: "/")
        if components.count >= 2, components[0] == "Volumes" {
            let mount = "/Volumes/\(components[1])"
            guard volume.mountPoint == mount || volume.mountPoint.hasPrefix(mount + "/") else {
                return refuse("\(mount) is not a mounted drive",
                              fix: "connect the drive and check that it shows in Finder, then run setup again")
            }
        }
        guard volume.fileSystem == "apfs" else {
            return refuse("\(volume.mountPoint) is \(volume.fileSystem), not APFS",
                          fix: "copy off what you keep, erase the drive as APFS in Disk Utility (this deletes "
                              + "everything on it), then run setup again")
        }
        guard !volume.ignoresOwnership else {
            return refuse("\(volume.mountPoint) ignores file ownership; turning it on needs an administrator, "
                              + "so run this yourself, then run setup again",
                          fix: "sudo diskutil enableOwnership \(shellWord(volume.mountPoint))")
        }
        let location = volume.mountPoint == path ? path : "\(path) (on \(volume.mountPoint))"
        return SandboxEligibility.Check(level: .pass, name: "Work disk", detail: "\(location): APFS, ownership on")
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
