import Foundation
import Darwin

/// Read-only view of this user's running processes and their command lines.
/// Used to decide whether a recorded process is still alive; it signals nothing.
public enum ClusterProcessTable {
    public struct Entry: Equatable, Sendable {
        public let processIdentifier: Int32
        public let arguments: [String]
        /// The parent at the time of the read; 1 once the parent is gone (the
        /// kernel reparents to launchd). Nil when the table could not say.
        public let parentProcessIdentifier: Int32?
        /// Last path component of the executable; nil when it cannot be read.
        public let executableName: String?
        /// Seconds since 1970 when the process started; nil when unknown.
        public let startedAt: Double?
        public init(processIdentifier: Int32, arguments: [String], parentProcessIdentifier: Int32? = nil,
                    executableName: String? = nil, startedAt: Double? = nil) {
            self.processIdentifier = processIdentifier; self.arguments = arguments
            self.parentProcessIdentifier = parentProcessIdentifier; self.executableName = executableName
            self.startedAt = startedAt
        }
    }

    /// Every process whose arguments this user may read. A process whose
    /// arguments cannot be read belongs to another user.
    public static func running() -> [Entry] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        var identifiers = [Int32](repeating: 0, count: capacity + 64)
        let filled = identifiers.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return identifiers.prefix(Int(filled)).compactMap { identifier in
            guard identifier > 0, let arguments = arguments(of: identifier) else { return nil }
            let info = bsdInfo(identifier)
            return .init(processIdentifier: identifier, arguments: arguments,
                         parentProcessIdentifier: info.map { Int32($0.pbi_ppid) },
                         executableName: executableName(identifier),
                         startedAt: info.map { Double($0.pbi_start_tvsec) + Double($0.pbi_start_tvusec) / 1e6 })
        }
    }

    /// Nil when the process is gone or not readable by this user.
    public static func arguments(of identifier: Int32) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, identifier]
        var size = 0
        guard identifier > 0, sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 4096 else { return nil }
        // Layout: argc, executable path, NUL padding, then argc NUL-terminated arguments.
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var result = [String]()
        while result.count < Int(count), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    /// True while the process exists (a zombie counts as gone).
    public static func isAlive(_ identifier: Int32) -> Bool {
        guard identifier > 0, let info = bsdInfo(identifier) else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }

    /// The parent of a live process; nil when it is gone or unreadable.
    public static func parentProcessIdentifier(of identifier: Int32) -> Int32? {
        guard identifier > 0, let info = bsdInfo(identifier) else { return nil }
        return Int32(info.pbi_ppid)
    }

    static func executableName(_ identifier: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(identifier, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.split(separator: "/").last.map(String.init)
    }

    static func bsdInfo(_ identifier: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(identifier, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }
}
