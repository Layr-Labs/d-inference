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
 * Create a new identity in the Secure Enclave.
 * Returns NULL on failure (e.g., Secure Enclave unavailable).
 * Caller must free with eigeninference_enclave_free().
 */
EigenInferenceEnclaveIdentity eigeninference_enclave_create(void);

/*
 * Load an existing identity from a saved data representation.
 * The data representation is device-specific and opaque.
 * Returns NULL on failure.
 * Caller must free with eigeninference_enclave_free().
 */
EigenInferenceEnclaveIdentity eigeninference_enclave_load(const uint8_t* data, int data_len);

/*
 * Free an identity created by eigeninference_enclave_create() or eigeninference_enclave_load().
 */
void eigeninference_enclave_free(EigenInferenceEnclaveIdentity identity);

/*
 * Get the public key as a base64-encoded null-terminated string.
 * Caller must free the returned string with eigeninference_enclave_free_string().
 */
char* eigeninference_enclave_public_key_base64(EigenInferenceEnclaveIdentity identity);

/*
 * Get the data representation for persisting the identity.
 * If buffer is NULL, returns the required buffer size.
 * Otherwise copies up to buffer_len bytes and returns bytes written.
 */
int eigeninference_enclave_data_representation(
    EigenInferenceEnclaveIdentity identity,
    uint8_t* buffer,
    int buffer_len
);

/*
 * Create a new Secure Enclave key-agreement identity for E2E secret derivation.
 * Returns NULL on failure. Caller must free with eigeninference_enclave_free().
 */
EigenInferenceEnclaveIdentity eigeninference_enclave_key_agreement_create(void);

/*
 * Load an existing Secure Enclave key-agreement identity from an opaque blob.
 * Returns NULL on failure. Caller must free with eigeninference_enclave_free().
 */
EigenInferenceEnclaveIdentity eigeninference_enclave_key_agreement_load(
    const uint8_t* data,
    int data_len
);

/*
 * Get the key-agreement public key as a base64-encoded null-terminated string.
 * Caller must free the returned string with eigeninference_enclave_free_string().
 */
char* eigeninference_enclave_key_agreement_public_key_base64(
    EigenInferenceEnclaveIdentity identity
);

/*
 * Get the opaque data representation for persisting the key-agreement identity.
 * If buffer is NULL, returns the required buffer size.
 * Otherwise copies up to buffer_len bytes and returns bytes written.
 */
int eigeninference_enclave_key_agreement_data_representation(
    EigenInferenceEnclaveIdentity identity,
    uint8_t* buffer,
    int buffer_len
);

/*
 * Deterministically derive the provider's 32-byte X25519 E2E secret.
 * If buffer is NULL, returns the required size (32).
 * Returns -1 on failure.
 */
int eigeninference_enclave_key_agreement_derive_x25519_secret(
    EigenInferenceEnclaveIdentity identity,
    uint8_t* buffer,
    int buffer_len
);

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
 * Returns a pretty-printed JSON null-terminated string.
 * Caller must free the returned string with eigeninference_enclave_free_string().
 * Returns NULL on failure.
 */
char* eigeninference_enclave_create_attestation(EigenInferenceEnclaveIdentity identity);

/*
 * Free a string returned by any eigeninference_enclave_* function.
 */
void eigeninference_enclave_free_string(char* str);

#ifdef __cplusplus
}
#endif

#endif /* EIGENINFERENCE_ENCLAVE_H */
