// Package receipts creates and verifies signed, deterministic inference
// receipts: the coordinator's signed statement that one consumer request was
// dispatched, which attempt won, and exactly what it returned.
//
// What a receipt proves. A valid envelope shows that the coordinator holding
// the published key for KeyID committed to these facts together, bound to a
// nonce the verifier chose before sending the request:
//
//   - request_sha256 and request_bytes_sha256: the consumer's original
//     plaintext body, both canonicalized (so any client can recompute it) and
//     as exact bytes (so the sender can prove it was not re-encoded);
//   - provider_request_sha256: the body actually sealed to the winning
//     provider attempt, after coordinator normalization;
//   - output_sha256: the exact assistant text returned to the caller;
//   - the requested and resolved model, finish reason, caller key ID, and the
//     attempt that committed the response.
//
// The nonce makes the receipt fresh: it could not have been produced before
// the verifier picked the nonce, and the coordinator accepts each nonce once.
//
// What a receipt does not prove. It is a statement by the coordinator, not by
// the provider or the hardware, so it inherits the coordinator's trust (the
// confidential-VM and attestation model in docs/architecture/security). It
// does not show that the output is correct, that the resolved model's weights
// behaved as advertised, or anything about requests that were not completed.
// It contains digests only, never prompt or output text.
//
// Encoding. Payload field order and JSON names are part of the version-1
// wire format. CanonicalJSON's version 1 accepts exactly one top-level JSON
// object, rejects duplicate decoded keys in objects at every depth, and
// preserves json.Number lexemes. It emits compact encoding/json output with
// sorted map keys and encoding/json's default string escaping. It rejects raw
// inputs over 16 MiB and nested arrays or objects deeper than 256 levels,
// counting the root object as level 1.
//
// Configuration. Config (config.go) reads the opt-in switch and key material
// from EIGENINFERENCE_INFERENCE_RECEIPT* variables; Config.Check fails the
// coordinator boot when receipts are enabled with unusable keys, and
// Config.KeyRing builds the signer and published verification keys.
package receipts
