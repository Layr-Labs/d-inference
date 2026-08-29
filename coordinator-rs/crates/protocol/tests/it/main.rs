//! Single integration-test binary for `darkbloom-protocol`: cross-language
//! golden-vector compatibility against the Go coordinator.
//!
//! Module map — what each module proves:
//! - `golden_v1` — every Go-marshaled JSON v1 frame decodes into the Rust
//!   types and re-encodes semantically identically (omitempty, null-vs-absent,
//!   byte-exact signed attestation payloads).
//! - `crypto::box_vectors` — NaCl Box interop with Go `nacl/box`, both
//!   directions, including precomputed shared keys and tamper rejection.
//! - `crypto::sealed_sender` — sealed-sender request/response/SSE envelopes
//!   open and re-seal byte-identically to the Go implementation.
//! - `crypto::signing` — Secure Enclave P-256 vectors: challenge signatures,
//!   canonical status bytes, and raw attestation blob verification.
//! - `support` — vector-file loading helpers (`fixtures/vectors/`, regenerated
//!   by `go run ./coordinator-rs/fixtures/gen` from the repo root).

mod crypto;
mod golden_v1;
mod support;
