import Foundation
import Darwin

/// Read-only view of this user's running processes and their command lines.
/// Used to decide whether a recorded process is still alive; it signals nothing.
public enum ClusterProcessTable {
    public struct Entry: Equatable, Sendable {
        public let processIdentifier: Int32
        public let arguments: [String]
        public init(processIdentifier: Int32, arguments: [String]) {
            self.processIdentifier = processIdentifier; self.arguments = arguments
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
            return .init(processIdentifier: identifier, arguments: arguments)
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
}
