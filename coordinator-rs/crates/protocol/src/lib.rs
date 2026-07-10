//! Wire protocol and cryptographic compatibility for the Darkbloom coordinator.
//!
//! This crate owns:
//! - Provider WebSocket wire types, JSON v1 (compatible with today's Swift
//!   provider fleet and `coordinator/protocol/messages.go`).
//! - Protocol v2 frames: prepare / prepared / start / started / abort /
//!   cancel / terminal / ACK, with job/attempt/lease identity and epoch fencing.
//! - Binary encrypted-payload frame codec (fixed header + raw ciphertext).
//! - NaCl Box (X25519 + XSalsa20-Poly1305) compatibility with the Go
//!   `coordinator/internal/e2e` implementation and the Swift provider.
//! - Secure Enclave P-256 signature verification over canonical payloads.
//!
//! No tokio, no sqlx, no I/O: everything here is pure encode/decode/verify.
