import Foundation
import Darwin

enum ClusterLinkMachineIdentity {
    /// This Mac's hardware UUID, the value that differs between the two ends
    /// of a cable. It only feeds `ClusterLinkLocalAddress.derived`.
    static func hardwareUUID() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        guard gethostuuid(&bytes, &timeout) == 0 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
