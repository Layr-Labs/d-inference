import Foundation

/// The only text the link inspection keeps from tool output. A leading ASCII
/// letter followed by letters and digits (plus `_` for devices) can never be
/// an option, an IP address, a MAC address or a GID.
enum ClusterLinkName {
    /// 63 bytes is the native RDMA device-name limit.
    static func isDevice(_ text: String) -> Bool {
        matches(text, maximumBytes: 63, allowingUnderscore: true)
    }

    /// 15 bytes is the kernel's interface-name limit.
    static func isInterface(_ text: String) -> Bool {
        matches(text, maximumBytes: 15, allowingUnderscore: false)
    }

    /// macOS names the RDMA device of interface `en7` `rdma_en7`. Nil for any
    /// other shape: no interface is guessed.
    static func interface(ofDevice device: String) -> String? {
        let prefix = "rdma_"
        guard device.hasPrefix(prefix) else { return nil }
        let interface = String(device.dropFirst(prefix.count))
        return isInterface(interface) ? interface : nil
    }

    private static func matches(_ text: String, maximumBytes: Int, allowingUnderscore: Bool) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...maximumBytes).contains(bytes.count), isLetter(bytes[0]) else { return false }
        return bytes.allSatisfy { isLetter($0) || isDigit($0) || (allowingUnderscore && $0 == UInt8(ascii: "_")) }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
