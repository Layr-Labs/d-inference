#ifndef DGINF_ENCLAVE_H
#define DGINF_ENCLAVE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to a SecureEnclaveIdentity */
typedef void* DGInfEnclaveIdentity;

/*
 * Check if the Secure Enclave is available on this device.
 * Returns 1 if available, 0 if not.
 */
int32_t dginf_enclave_is_available(void);

/*
 * Create a new identity in the Secure Enclave.
 * Returns NULL on failure (e.g., Secure Enclave unavailable).
 * Caller must free with dginf_enclave_free().
 */
DGInfEnclaveIdentity dginf_enclave_create(void);

/*
 * Load an existing identity from a saved data representation.
 * The data representation is device-specific and opaque.
 * Returns NULL on failure.
 * Caller must free with dginf_enclave_free().
 */
DGInfEnclaveIdentity dginf_enclave_load(const uint8_t* data, int data_len);

/*
 * Free an identity created by dginf_enclave_create() or dginf_enclave_load().
 */
void dginf_enclave_free(DGInfEnclaveIdentity identity);

/*
 * Get the public key as a base64-encoded null-terminated string.
 * Caller must free the returned string with dginf_enclave_free_string().
 */
char* dginf_enclave_public_key_base64(DGInfEnclaveIdentity identity);

/*
 * Get the data representation for persisting the identity.
 * If buffer is NULL, returns the required buffer size.
 * Otherwise copies up to buffer_len bytes and returns bytes written.
 */
int dginf_enclave_data_representation(
    DGInfEnclaveIdentity identity,
    uint8_t* buffer,
    int buffer_len
);

/*
 * Sign data with the Secure Enclave private key.
 * Returns the DER-encoded ECDSA signature as a base64 null-terminated string.
 * Caller must free the returned string with dginf_enclave_free_string().
 * Returns NULL on failure.
 */
char* dginf_enclave_sign(
    DGInfEnclaveIdentity identity,
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
int32_t dginf_enclave_verify(
    const char* pub_key_base64,
    const uint8_t* data,
    int data_len,
    const char* sig_base64
);

/*
 * Create a signed attestation blob containing hardware/software state.
 * Returns a pretty-printed JSON null-terminated string.
 * Caller must free the returned string with dginf_enclave_free_string().
 * Returns NULL on failure.
 */
char* dginf_enclave_create_attestation(DGInfEnclaveIdentity identity);

/*
 * Free a string returned by any dginf_enclave_* function.
 */
void dginf_enclave_free_string(char* str);

#ifdef __cplusplus
}
#endif

#endif /* DGINF_ENCLAVE_H */
