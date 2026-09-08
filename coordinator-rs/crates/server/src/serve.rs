//! Socket-level HTTP serving (plan §15.1, §16) — the accept loop the
//! `coordinator-rs serve` binary and the full-stack tests share.
//!
//! # Protocol posture (production topology)
//!
//! The coordinator serves **plaintext HTTP on localhost behind a host Caddy
//! reverse proxy** that terminates TLS. Caddy speaks HTTP/1.1 to upstreams
//! by default, so HTTP/1.1 with keep-alive is the primary wire; the
//! hyper-util auto builder additionally accepts **h2c prior-knowledge**
//! (client HTTP/2 preface on the plaintext socket), so a Caddyfile that
//! configures `transport http { versions h2c }` keeps working without a
//! coordinator change. There is no ALPN and no TLS here by design — TLS is
//! Caddy's job.
//!
//! # Why not plain `axum::serve`
//!
//! Two production-relevant gaps, both verified against axum 0.8 / hyper 1.x
//! sources and pinned by the `net_*` integration tests:
//!
//! - **`TCP_NODELAY` is not set** on accepted connections. Without it,
//!   Nagle's algorithm holds every small SSE token frame until the previous
//!   segment is ACKed (≈40 ms with delayed ACK), destroying the per-chunk
//!   relay budget (plan §16: p99 < 2 ms). This loop sets it at accept time,
//!   which also covers upgraded provider WebSockets on the same socket.
//! - **The header read timeout is silently disabled.** hyper 1 defaults
//!   `header_read_timeout` to 30 s but requires a timer; `axum::serve`
//!   builds the hyper-util auto builder without one, so hyper logs
//!   "timeout has default, but no timer set" and slowloris protection is
//!   OFF. This loop installs [`TokioTimer`] and an explicit timeout.
//!
//! # Timeout coverage
//!
//! - Header read: [`ServeOptions::header_read_timeout`] (slowloris).
//! - Request body read: enforced per-route where a body is collected
//!   (`http::chat` — see [`crate::http::BODY_READ_TIMEOUT`]).
//! - Responses: **no blanket response timeout layer exists anywhere** —
//!   deliberately, so long SSE generations are never killed by a generic
//!   timeout. Stream lifetime is bounded by the request task's own
//!   deadlines (first-content, stream-idle, absolute request deadline —
//!   plan §16).
//!
//! # Shutdown
//!
//! On cancellation the loop stops accepting, sends HTTP-level graceful
//! shutdown to every live connection (in-flight responses — including SSE
//! streams — run to completion; request tasks are cancelled separately by
//! the supervisor's requests phase, which ends those streams promptly with
//! a clean chunked-body termination), and waits for connection tasks.
//! Upgraded WebSockets detach from their originating connection at upgrade
//! time and are NOT waited on here — the supervisor's sessions phase fences
//! them (plan §15.1; axum graceful shutdown alone would wait forever).

use std::io;
use std::pin::pin;
use std::time::Duration;

use axum::Router;
use hyper::body::Incoming;
use hyper::Request;
use hyper_util::rt::{TokioExecutor, TokioIo, TokioTimer};
use hyper_util::server::conn::auto::Builder;
use hyper_util::service::TowerToHyperService;
use tokio::net::{TcpListener, TcpStream};
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;
use tower::ServiceExt;

/// Socket-level tunables. Defaults are the production posture; tests
/// shrink the timeouts.
#[derive(Debug, Clone, Copy)]
pub struct ServeOptions {
    /// Slowloris bound: a connection that has not delivered a complete
    /// request header block within this window is closed (hyper's own
    /// default of 30 s, here actually armed — see the module docs).
    pub header_read_timeout: Duration,
}

impl Default for ServeOptions {
    fn default() -> Self {
        Self {
            header_read_timeout: Duration::from_secs(30),
        }
    }
}

/// Serves `router` on `listener` until `shutdown` fires, then gracefully
/// drains live connections (see the module docs for the exact semantics).
pub async fn serve(
    listener: TcpListener,
    router: Router,
    options: ServeOptions,
    shutdown: CancellationToken,
) -> io::Result<()> {
    let connections = TaskTracker::new();

    loop {
        let accepted = tokio::select! {
            biased;
            () = shutdown.cancelled() => break,
            accepted = listener.accept() => accepted,
        };
        let stream = match accepted {
            Ok((stream, _remote)) => stream,
            Err(err) => {
                handle_accept_error(err).await;
                continue;
            }
        };
        // Per-chunk latency depends on this (module docs); a failure is
        // non-fatal but worth surfacing.
        if let Err(err) = stream.set_nodelay(true) {
            tracing::warn!(error = %err, "TCP_NODELAY failed on accepted connection");
        }
        connections.spawn(serve_connection(
            stream,
            router.clone(),
            options,
            shutdown.clone(),
        ));
    }

    // Stop accepting first, then drain. The caller (bootstrap::App::serve)
    // bounds this wait with the shutdown phase timeout.
    drop(listener);
    connections.close();
    connections.wait().await;
    Ok(())
}

/// One connection: hyper-util auto (HTTP/1.1 + h2c) with upgrades, a real
/// timer, and graceful shutdown on cancellation.
async fn serve_connection(
    stream: TcpStream,
    router: Router,
    options: ServeOptions,
    shutdown: CancellationToken,
) {
    let service = TowerToHyperService::new(
        router.map_request(|request: Request<Incoming>| request.map(axum::body::Body::new)),
    );

    let mut builder = Builder::new(TokioExecutor::new());
    builder
        .http1()
        .timer(TokioTimer::new())
        .header_read_timeout(options.header_read_timeout)
        .keep_alive(true);
    builder
        .http2()
        .timer(TokioTimer::new())
        // CONNECT protocol for HTTP/2 WebSocket bootstraps (axum parity).
        .enable_connect_protocol();

    let io = TokioIo::new(stream);
    let mut conn = pin!(builder.serve_connection_with_upgrades(io, service));
    tokio::select! {
        result = conn.as_mut() => {
            if let Err(err) = result {
                tracing::trace!(error = %err, "connection ended with error");
            }
        }
        () = shutdown.cancelled() => {
            // In-flight responses finish; keep-alive connections close. WS
            // upgrades have already detached (module docs).
            conn.as_mut().graceful_shutdown();
            if let Err(err) = conn.as_mut().await {
                tracing::trace!(error = %err, "connection ended with error during shutdown");
            }
        }
    }
}

/// Accept-loop error policy (axum parity): per-connection failures are
/// dropped; resource exhaustion backs off instead of spinning hot.
async fn handle_accept_error(err: io::Error) {
    if is_connection_error(&err) {
        return;
    }
    // [From `axum::serve`] A possible scenario is the process ran out of
    // file descriptors: sleep so other tasks can close files and yield the
    // accept loop.
    tracing::error!(error = %err, "accept error; backing off");
    tokio::time::sleep(Duration::from_secs(1)).await;
}

fn is_connection_error(err: &io::Error) -> bool {
    matches!(
        err.kind(),
        io::ErrorKind::ConnectionRefused
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::ConnectionReset
    )
}
