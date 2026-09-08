import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct SecureEnclaveBootKeyEngine: BootKeyEngine {
    var isAvailable: Bool { SecureEnclave.isAvailable }

    func create() throws -> any BootHardwareKey {
        let context = noInteractionContext()
        var error: Unmanaged<CFError>?
        // Class F is private SPI (SecItemPriv.h), not a public SDK guarantee.
        // Do not substitute another protection if the platform rejects it.
        guard let access = SecAccessControlCreateWithFlags(nil, "f" as CFString, .privateKeyUsage, &error) else {
            _ = error?.takeRetainedValue()
            throw BootContinuityError.keyUnavailable
        }
        do {
            return EnclaveKey(try SecureEnclave.P256.Signing.PrivateKey(
                accessControl: access, authenticationContext: context))
        } catch { throw BootContinuityError.keyUnavailable }
    }

    func recover(handle: Data) throws -> any BootHardwareKey {
        do {
            return EnclaveKey(try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: handle, authenticationContext: noInteractionContext()))
        } catch { throw BootContinuityError.keyUnavailable }
    }

    private func noInteractionContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}

private struct EnclaveKey: BootHardwareKey {
    let key: SecureEnclave.P256.Signing.PrivateKey

    init(_ key: SecureEnclave.P256.Signing.PrivateKey) { self.key = key }
    var publicKey: Data { key.publicKey.rawRepresentation }
    var opaqueHandle: Data { key.dataRepresentation }

    func sign(_ message: Data) throws -> Data {
        do { return try key.signature(for: message).derRepresentation }
        catch { throw BootContinuityError.keyUnavailable }
    }
}
