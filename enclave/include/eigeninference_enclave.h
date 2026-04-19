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
