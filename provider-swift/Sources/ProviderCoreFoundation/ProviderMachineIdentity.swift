import Crypto
import Foundation

/// Stable, opaque grouping key shared with the coordinator's authenticated
/// earnings response. The namespace prevents this digest from being confused
/// with a hash used for any other purpose.
public enum ProviderMachineIdentity {
    private static let namespace = "darkbloom-provider-machine-v1\u{0}"

    public static func id(serialNumber: String) -> String? {
        guard !serialNumber.isEmpty else { return nil }
        return SHA256.hash(data: Data((namespace + serialNumber).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
