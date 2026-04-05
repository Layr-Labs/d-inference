/// FFI Bridge — C-callable functions for Rust integration.
///
/// These @_cdecl functions provide a C ABI so the Rust provider agent can
/// call Secure Enclave operations via FFI. The Rust side loads the compiled
/// Swift framework and calls these functions through their C symbols.
///
/// Memory management convention:
///   - Functions returning `UnsafeMutableRawPointer?` (identity objects) use
///     `Unmanaged.passRetained` — caller must eventually call `eigeninference_enclave_free()`
///   - Functions returning `UnsafeMutablePointer<CChar>?` (strings) use `strdup`
///     — caller must eventually call `eigeninference_enclave_free_string()`
///   - NULL return values indicate failure (Secure Enclave unavailable, invalid
///     data, signing error, etc.)
///
/// The corresponding C header would be in include/eigeninference_enclave.h (not yet
/// generated — the Rust side currently uses the symbols directly).
///
/// Available operations:
///   - Create/load/free identity (Secure Enclave key management)
///   - Get public key (base64 string)
///   - Get data representation (for persisting identity)
///   - Sign data (returns base64 DER signature)
///   - Verify signature (against any P-256 public key)
///   - Create attestation (with optional encryption key binding)

import CryptoKit
import Foundation

// MARK: - C-callable FFI bridge functions

/// Create a new Secure Enclave identity. Returns an opaque pointer.
///
/// Generates a new P-256 key in the Secure Enclave. The pointer must be
/// freed with `eigeninference_enclave_free()` when no longer needed.
/// Returns NULL if the Secure Enclave is unavailable or key creation fails.
@_cdecl("eigeninference_enclave_create")
public func eigeninference_enclave_create() -> UnsafeMutableRawPointer? {
    guard SecureEnclave.isAvailable else { return nil }
    guard let identity = try? SecureEnclaveIdentity() else { return nil }
    return Unmanaged.passRetained(identity as AnyObject).toOpaque()
}

/// Load an existing identity from a saved data representation.
///
/// The data representation is an opaque handle from a previous
/// `eigeninference_enclave_data_representation()` call. It only works on the
/// same device that generated the original key.
/// Returns NULL on failure (wrong device, corrupted data, etc.).
@_cdecl("eigeninference_enclave_load")
public func eigeninference_enclave_load(
    _ dataPtr: UnsafePointer<UInt8>,
    _ dataLen: Int
) -> UnsafeMutableRawPointer? {
    let data = Data(bytes: dataPtr, count: dataLen)
    guard let identity = try? SecureEnclaveIdentity(dataRepresentation: data) else {
        return nil
    }
    return Unmanaged.passRetained(identity as AnyObject).toOpaque()
}

/// Free an identity created by `eigeninference_enclave_create` or `eigeninference_enclave_load`.
///
/// This releases the retained reference to the SecureEnclaveIdentity object.
/// After calling this, the pointer must not be used again.
@_cdecl("eigeninference_enclave_free")
public func eigeninference_enclave_free(_ ptr: UnsafeMutableRawPointer) {
    Unmanaged<AnyObject>.fromOpaque(ptr).release()
}

/// Check if the Secure Enclave is available on this device.
/// Returns 1 if available, 0 if not.
@_cdecl("eigeninference_enclave_is_available")
public func eigeninference_enclave_is_available() -> Int32 {
    return SecureEnclave.isAvailable ? 1 : 0
}

/// Get the public key as a base64-encoded, null-terminated C string.
///
/// The public key is the raw P-256 point (64 bytes: X || Y), base64-encoded.
/// Caller must free the returned string with `eigeninference_enclave_free_string()`.
@_cdecl("eigeninference_enclave_public_key_base64")
public func eigeninference_enclave_public_key_base64(
    _ ptr: UnsafeRawPointer
) -> UnsafeMutablePointer<CChar>? {
    let identity = Unmanaged<SecureEnclaveIdentity>.fromOpaque(ptr)
        .takeUnretainedValue()
    let base64 = identity.publicKeyBase64
    return strdup(base64)
}

/// Get the data representation for persisting the identity.
///
/// The data representation is an opaque handle from the Secure Enclave.
/// It can be saved to disk and later passed to `eigeninference_enclave_load()` to
/// reload the same key on the same device.
///
/// If `buffer` is NULL, returns the required buffer size without writing.
/// Otherwise copies up to `bufferLen` bytes into `buffer` and returns the
/// number of bytes written.
@_cdecl("eigeninference_enclave_data_representation")
public func eigeninference_enclave_data_representation(
    _ ptr: UnsafeRawPointer,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ bufferLen: Int
) -> Int {
    let identity = Unmanaged<SecureEnclaveIdentity>.fromOpaque(ptr)
        .takeUnretainedValue()
    let data = identity.dataRepresentation

    if let buffer = buffer, bufferLen >= data.count {
        data.copyBytes(to: buffer, count: data.count)
    }
    return data.count
}

/// Sign data with the Secure Enclave private key.
///
/// The signing operation happens inside the Secure Enclave hardware.
/// Returns the DER-encoded ECDSA signature as a base64 null-terminated C string.
/// Caller must free with `eigeninference_enclave_free_string()`.
/// Returns NULL on failure (e.g., Secure Enclave unavailable, biometric denied).
@_cdecl("eigeninference_enclave_sign")
public func eigeninference_enclave_sign(
    _ ptr: UnsafeRawPointer,
    _ dataPtr: UnsafePointer<UInt8>,
    _ dataLen: Int
) -> UnsafeMutablePointer<CChar>? {
    let identity = Unmanaged<SecureEnclaveIdentity>.fromOpaque(ptr)
        .takeUnretainedValue()
    let data = Data(bytes: dataPtr, count: dataLen)
    guard let signature = try? identity.sign(data) else { return nil }
    return strdup(signature.base64EncodedString())
}

/// Verify a P-256 ECDSA signature.
///
/// This is a standalone verification that does not require a Secure Enclave
/// identity — it uses any P-256 public key provided as raw bytes (base64).
///
/// - Parameters:
///   - pubKeyBase64: The signer's public key (raw representation, base64).
///   - dataPtr/dataLen: The signed data.
///   - sigBase64: The DER-encoded signature (base64).
///
/// Returns 1 if the signature is valid, 0 otherwise.
@_cdecl("eigeninference_enclave_verify")
public func eigeninference_enclave_verify(
    _ pubKeyBase64: UnsafePointer<CChar>,
    _ dataPtr: UnsafePointer<UInt8>,
    _ dataLen: Int,
    _ sigBase64: UnsafePointer<CChar>
) -> Int32 {
    let pubKeyStr = String(cString: pubKeyBase64)
    let sigStr = String(cString: sigBase64)

    guard let pubKeyData = Data(base64Encoded: pubKeyStr),
          let sigData = Data(base64Encoded: sigStr) else {
        return 0
    }

    let data = Data(bytes: dataPtr, count: dataLen)
    return SecureEnclaveIdentity.verify(
        signature: sigData,
        for: data,
        publicKey: pubKeyData
    ) ? 1 : 0
}

/// Create a signed attestation blob containing hardware/software state.
///
/// This is a convenience wrapper that calls
/// `eigeninference_enclave_create_attestation_with_key` with no encryption key.
///
/// Returns the signed attestation as a pretty-printed JSON C string.
/// Caller must free with `eigeninference_enclave_free_string()`.
/// Returns NULL on failure.
@_cdecl("eigeninference_enclave_create_attestation")
public func eigeninference_enclave_create_attestation(
    _ ptr: UnsafeRawPointer
) -> UnsafeMutablePointer<CChar>? {
    return eigeninference_enclave_create_attestation_with_key(ptr, nil)
}

/// Create a signed attestation blob that binds an encryption public key.
///
/// The encryption key (X25519, base64-encoded) is included in the attestation
/// blob, binding it to the Secure Enclave identity. The coordinator verifies
/// that this key matches the public_key in the Register message, proving
/// both keys belong to the same physical device.
///
/// - Parameters:
///   - ptr: Opaque pointer to a SecureEnclaveIdentity.
///   - encryptionKeyBase64: Optional base64-encoded X25519 public key to bind.
///
/// Returns the signed attestation as a pretty-printed JSON C string.
/// Caller must free with `eigeninference_enclave_free_string()`.
/// Returns NULL on failure.
@_cdecl("eigeninference_enclave_create_attestation_with_key")
public func eigeninference_enclave_create_attestation_with_key(
    _ ptr: UnsafeRawPointer,
    _ encryptionKeyBase64: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    let identity = Unmanaged<SecureEnclaveIdentity>.fromOpaque(ptr)
        .takeUnretainedValue()
    let service = AttestationService(identity: identity)

    let encKey: String? = encryptionKeyBase64.map { String(cString: $0) }

    guard let signed = try? service.createAttestation(encryptionPublicKey: encKey) else { return nil }

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let jsonData = try? encoder.encode(signed),
          let jsonStr = String(data: jsonData, encoding: .utf8) else {
        return nil
    }

    return strdup(jsonStr)
}

/// Free a C string returned by any `eigeninference_enclave_*` function.
///
/// This calls the standard C `free()` on the pointer. Must be called for
/// every non-NULL string returned by the FFI functions to avoid memory leaks.
@_cdecl("eigeninference_enclave_free_string")
public func eigeninference_enclave_free_string(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}
