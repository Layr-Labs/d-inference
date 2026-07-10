//! One provider WebSocket connection: registration, epoch, two-lane writer,
//! frame demux, and attempt routing (plan §7.4, §15.2, §15.3).
//!
//! # Entry point
//!
//! `provider_session::serve(socket, deps)` — the HTTP adapter wires the
//! `GET /v1/providers/connect` upgrade to this call:
//!
//! ```ignore
//! router.route("/v1/providers/connect", get(|upgrade: WebSocketUpgrade| async {
//!     upgrade.max_message_size(deps.config.max_frame_bytes)
//!         .on_upgrade(move |socket| provider_session::serve(socket, deps))
//! }))
//! ```
//!
//! # Flow
//!
//! 1. Read the registration frame (v1 `register`; protocol v2 detected via
//!    the `protocol_v2` extension, [`json_v2::RegistrationV2`]).
//! 2. Verify identity evidence via the [`trust`](crate::trust) verifier
//!    (Secure Enclave attestation over raw preserved bytes; optional at the
//!    pilot trust level) and derive the stable `ProviderId`
//!    ([`registration::stable_provider_id`]).
//! 3. `FleetCommand::Connect` — the fleet mints the session epoch and the
//!    lane channels; the session receives [`contracts::ConnectAccept`].
//! 4. Split the socket: the [`writer`] task owns the sink and drains
//!    control-then-data with STRICT non-preemptive control priority,
//!    resolving each frame's `OnWire` oneshot after the socket write
//!    returns (Go `WriteText`-blocks-to-wire semantics, plan §15.2). The
//!    [`reader`] loop decodes and demuxes inbound frames.
//!
//! # v1 chunk ownership (design decision)
//!
//! The contract delivers the per-request session secret key to the request
//! task, never to the session — so the session CANNOT decrypt v1 chunks.
//! Instead it validates the sender key (the payload's ephemeral key must
//! equal the provider's registered X25519 key — plan §9.1.7), base64-decodes
//! the ciphertext, and forwards the RAW `nonce || box` bytes through the
//! [`contracts::ChunkSender`] — the exact input the request task's
//! precomputed shared key opens. The request task owns decryption: one
//! `nacl_box::precompute_shared_key` per attempt, then one symmetric open
//! per chunk (the Go `chunkKeyCache` equivalent, moved to the natural owner
//! of the key). The session never holds request key material and never
//! logs chunk bytes.
//!
//! # Keepalive and wire posture (design decision)
//!
//! The coordinator does NOT send WebSocket pings. Liveness is
//! provider-driven: heartbeats arrive every ~30 s and any inbound frame
//! advances the session's read deadline ([`SessionConfig::read_timeout`],
//! 90 s — the Go eviction-sweep parity); a silent socket is torn down at
//! the deadline. Inbound provider pings are answered automatically by the
//! WebSocket layer (tungstenite queues the pong), which also keeps Caddy's
//! proxied connection active. Outbound stalls are caught independently by
//! the writer's per-frame [`SessionConfig::write_timeout`] — including the
//! final close handshake. permessage-deflate is never negotiated (axum
//! offers no deflate extension): chunk payloads are ciphertext, so
//! compression would be pure CPU waste.
//!
//! # Supersede fencing (design decision)
//!
//! The fleet is the epoch authority. On supersede it (1) submits the
//! reserved in-band fence sentinel ([`writer::FENCE_FRAME`]) on the OLD
//! epoch's control lane — the writer recognizes it and tears down
//! immediately — and (2) drops its [`contracts::SessionHandle`], so even if
//! the sentinel could not be enqueued, the lanes close once outstanding
//! grant clones drop (the fallback fence). Either way: queued writes
//! resolve with [`WriteError`](crate::contracts::WriteError), the socket
//! closes, attached attempts get
//! [`AttemptEvent::SessionLost`](crate::contracts::AttemptEvent), and the
//! old session's own `Disconnect{epoch}` is ignored by the fleet as stale
//! (plan §9.1.2). Teardown from the old epoch can never remove the new
//! session.
//!
//! Module layout: [`lifecycle`] (registration handshake + reader/writer
//! wiring), [`deps`] (config/deps/context), [`reader`] + [`delivery`]
//! (read loop + event delivery policy), [`writer`] (two-lane writer),
//! [`registration`], [`challenge`], [`heartbeat`], [`v1`], [`v2`] +
//! [`v2_chunks`] (demux handlers), [`attempts`] (attachment table).

mod attempts;
mod challenge;
mod delivery;
mod deps;
mod heartbeat;
mod lifecycle;
mod reader;
mod registration;
mod v1;
mod v2;
mod v2_chunks;
mod writer;

#[allow(unused_imports)] // doc links
use darkbloom_protocol::json_v2;

pub use deps::{NoProviderAuth, SessionConfig, SessionDeps};
pub use lifecycle::serve;
pub use registration::{stable_provider_id, PROVIDER_ID_NAMESPACE};

pub(crate) use deps::SessionContext;
pub(crate) use writer::FENCE_FRAME;
