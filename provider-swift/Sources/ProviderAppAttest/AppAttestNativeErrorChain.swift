import Foundation
@preconcurrency import DeviceCheck

/// One closed-bucket link of a DeviceCheck failure's NSError chain. Only the
/// domain bucket and the int32 code cross the wire; never a description,
/// userInfo value or arbitrary domain string.
public struct AppAttestNativeErrorEntry: Codable, Sendable, Equatable {
    public enum Domain: String, Codable, Sendable, Equatable {
        case devicecheck, osstatus, url, cocoa, cryptotokenkit, aks, other
    }

    public let domain: Domain
    public let code: Int32

    public init(domain: Domain, code: Int32) {
        self.domain = domain
        self.code = code
    }
}

/// Walks `NSUnderlyingErrorKey` from the top-level callback error. Entry 0 is
/// the top-level error; an `AKSError` integer in an entry's userInfo adds an
/// `aks` entry right after it (devicecheckd reports Secure Enclave key loss
/// as CryptoTokenKit -3 with `AKSError=-536362989`).
public enum AppAttestNativeErrorChain {
    public static let maxEntries = 4
    /// userInfo key under which CryptoTokenKit/SecKey errors carry the
    /// AppleKeyStore status.
    static let aksUserInfoKey = "AKSError"
    /// `TKErrorDomain`; spelled out so this module need not link CryptoTokenKit.
    static let cryptoTokenKitDomain = "CryptoTokenKit"

    public static func entries(_ error: NSError) -> [AppAttestNativeErrorEntry] {
        var out: [AppAttestNativeErrorEntry] = []
        var current: NSError? = error
        var visited = 0
        while let node = current, out.count < maxEntries, visited < maxEntries {
            visited += 1
            if let code = int32(node.code) { out.append(AppAttestNativeErrorEntry(domain: domain(node.domain), code: code)) }
            if out.count < maxEntries, let aks = aksCode(node.userInfo[aksUserInfoKey]) {
                out.append(AppAttestNativeErrorEntry(domain: .aks, code: aks))
            }
            current = node.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return out
    }

    static func domain(_ value: String) -> AppAttestNativeErrorEntry.Domain {
        switch value {
        case DCErrorDomain: return .devicecheck
        case NSOSStatusErrorDomain: return .osstatus
        case NSURLErrorDomain: return .url
        case NSCocoaErrorDomain: return .cocoa
        case cryptoTokenKitDomain: return .cryptotokenkit
        default: return .other
        }
    }

    /// A value that fits in 32 bits, signed or unsigned, keeps its bit
    /// pattern as a signed int32 (0xe007c013 → -536362989). Anything wider
    /// has no faithful int32 form and is dropped.
    static func int32(_ value: Int) -> Int32? {
        guard value >= Int(Int32.min), value <= Int(UInt32.max) else { return nil }
        return Int32(truncatingIfNeeded: value)
    }

    private static func aksCode(_ value: Any?) -> Int32? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return int32(number.intValue)
    }
}
