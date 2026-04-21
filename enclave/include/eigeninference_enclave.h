#ifndef EIGENINFERENCE_ENCLAVE_H
#define EIGENINFERENCE_ENCLAVE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to a SecureEnclaveIdentity */
typedef void* EigenInferenceEnclaveIdentity;

/*
 * Check if the Secure Enclave is available on this device.
 * Returns 1 if available, 0 if not.
 */
int32_t eigeninference_enclave_is_available(void);

/*
 * Create a new ephemeral identity in the Secure Enclave.
 * The key exists only while the returned handle is alive.
 * Returns NULL on failure (e.g., Secure Enclave unavailable).
 * Caller must free with eigeninference_enclave_free().
 */
EigenInferenceEnclaveIdentity eigeninference_enclave_create(void);

/*
 * Free an identity created by eigeninference_enclave_create().
 */
void eigeninference_enclave_free(EigenInferenceEnclaveIdentity identity);

/*
 * Get the public key as a base64-encoded null-terminated string.
 * Caller must free the returned string with eigeninference_enclave_free_string().
 */
char* eigeninference_enclave_public_key_base64(EigenInferenceEnclaveIdentity identity);

/*
 * Sign data with the Secure Enclave private key.
 * Returns the DER-encoded ECDSA signature as a base64 null-terminated string.
 * Caller must free the returned string with eigeninference_enclave_free_string().
 * Returns NULL on failure.
 */
char* eigeninference_enclave_sign(
    EigenInferenceEnclaveIdentity identity,
    const uint8_t* data,
    int data_len
);

/*
 * Verify a P-256 ECDSA signature.
 *   pub_key_base64: signer's raw public key (base64)
 *   data/data_len:  the signed data
 *   sig_base64:     DER-encoded signature (base64)
 * Returns 1 if valid, 0 if invalid.
 */
int32_t eigeninference_enclave_verify(
    const char* pub_key_base64,
    const uint8_t* data,
    int data_len,
    const char* sig_base64
);

/*
 * Create a signed attestation blob containing hardware/software state.
 * Returns a JSON null-terminated string.
 * Caller must free the returned string with eigeninference_enclave_free_string().
 * Returns NULL on failure.
 */
char* eigeninference_enclave_create_attestation(EigenInferenceEnclaveIdentity identity);

/*
 * Create a signed attestation blob with encryption key and binary hash binding.
 *   encryptionKeyBase64: optional X25519 public key (base64), NULL to omit
 *   binaryHashHex:       optional SHA-256 hash of provider binary (hex), NULL to omit
 * Returns JSON null-terminated string.
 * Caller must free the returned string with eigeninference_enclave_free_string().
 * Returns NULL on failure.
 */
char* eigeninference_enclave_create_attestation_full(
    EigenInferenceEnclaveIdentity identity,
    const char* encryptionKeyBase64,
    const char* binaryHashHex
);

/*
 * Free a string returned by any eigeninference_enclave_* function.
 */
void eigeninference_enclave_free_string(char* str);

#ifdef __cplusplus
}
#endif

#endif /* EIGENINFERENCE_ENCLAVE_H */
