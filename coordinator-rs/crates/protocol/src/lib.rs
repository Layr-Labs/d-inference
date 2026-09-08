//! Wire protocol and cryptographic compatibility for the Darkbloom coordinator.
//!
//! This crate owns:
//! - [`json_v1`]: provider WebSocket wire types (compatible with today's Swift
//!   provider fleet and `coordinator/protocol/messages.go`). The Go encoder is
//!   ground truth: field names, `omitempty` behavior, and base64 encodings are
//!   mirrored field-for-field and pinned by cross-language golden vectors in
//!   `coordinator-rs/fixtures/vectors/`.
//! - [`json_v2`]: protocol v2 frames — prepare / prepared / start / started /
//!   abort / aborted / cancel / cancelled / terminal / terminal_ack and model
//!   lifecycle events, with job/attempt/lease identity and epoch fencing.
//! - [`binary`]: the binary encrypted-payload frame codec (fixed little-endian
//!   header + raw ciphertext, zero-copy decode).
//! - [`crypto`]: NaCl Box (X25519 + XSalsa20-Poly1305) compatibility with the
//!   Go `coordinator/internal/e2e` implementation and the Swift provider,
//!   sender-sealed transport envelopes, and Secure Enclave P-256 signature
//!   verification over canonical payloads.
//!
//! No tokio, no sqlx, no I/O: everything here is pure encode/decode/verify.
//!
//! Privacy invariant: no error produced by this crate embeds plaintext,
//! prompt bytes, or decoded field values. Decode errors carry only the frame
//! type and the parser position.

pub mod binary;
pub mod crypto;
pub mod json_v1;
pub mod json_v2;
