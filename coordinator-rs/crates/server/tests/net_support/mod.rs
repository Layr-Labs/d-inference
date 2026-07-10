//! Socket-level test support for the `net_*` suites: a real server on an
//! ephemeral port (through the SHIPPED `darkbloom_server::serve` loop), a
//! raw TCP HTTP/1.1 client (no client library — the tests must observe the
//! exact bytes and timing on the wire), and the v2 provider-script helpers
//! shared with the chat suites.

#![allow(dead_code)]

use std::net::SocketAddr;
use std::time::Duration;

use axum::Router;
use bytes::Bytes;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use darkbloom_core::ids::LeaseId;
use darkbloom_protocol::json_v2::{
    self, ExecutionFacts, FrameV2, PrepareFrame, PreparedFrame, RequestScope, ResourceFacts,
    RollingHashCheckpoint, TerminalFrame, TerminalUsage,
};
use darkbloom_server::contracts::{AttemptEvent, ControlFrame, DataFrame};
use darkbloom_server::serve::{serve, ServeOptions};

/// Private (NOT `pub`) so the glob imports of this module and the shared
/// harness never collide on the name.
const CONCRETE_MODEL: &str = "gemma-4-26b-4bit";

// ---------------------------------------------------------------------
// Real server on an ephemeral port
// ---------------------------------------------------------------------

pub struct NetServer {
    pub addr: SocketAddr,
    pub stop: CancellationToken,
    pub task: tokio::task::JoinHandle<std::io::Result<()>>,
}

impl NetServer {
    /// Serves `router` through the production serve loop.
    pub async fn spawn(router: Router, options: ServeOptions) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind");
        let addr = listener.local_addr().expect("local addr");
        let stop = CancellationToken::new();
        let task = tokio::spawn(serve(listener, router, options, stop.clone()));
        Self { addr, stop, task }
    }

    /// Serves `router` through plain `axum::serve` — the PRE-FIX posture
    /// (no TCP_NODELAY, no armed header timeout), kept only so the latency
    /// test can print a measured before/after comparison.
    pub async fn spawn_axum_baseline(router: Router) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind");
        let addr = listener.local_addr().expect("local addr");
        let stop = CancellationToken::new();
        let signal = {
            let stop = stop.clone();
            async move { stop.cancelled().await }
        };
        let task = tokio::spawn(async move {
            axum::serve(listener, router)
                .with_graceful_shutdown(signal)
                .await
        });
        Self { addr, stop, task }
    }

    pub async fn shutdown(self) {
        self.stop.cancel();
        self.task.abort();
        let _ = self.task.await;
    }
}

// ---------------------------------------------------------------------
// Raw TCP HTTP/1.1 client
// ---------------------------------------------------------------------

pub struct RawClient {
    pub stream: TcpStream,
}

pub struct RawResponse {
    pub status: u16,
    /// Lower-cased header name → value.
    pub headers: Vec<(String, String)>,
    /// Body bytes already buffered past the header terminator.
    pub body_prefix: Vec<u8>,
}

impl RawResponse {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_str())
    }
}

impl RawClient {
    pub async fn connect(addr: SocketAddr) -> Self {
        let stream = TcpStream::connect(addr).await.expect("connect");
        stream.set_nodelay(true).expect("client nodelay");
        Self { stream }
    }

    pub async fn send(&mut self, bytes: &[u8]) {
        self.stream.write_all(bytes).await.expect("client write");
    }

    /// Sends a chat-completions POST with the standard test credentials.
    pub async fn send_chat(&mut self, body: &serde_json::Value) {
        let body = serde_json::to_vec(body).expect("encode body");
        let head = format!(
            "POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer sk-test-token\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
            body.len()
        );
        self.send(head.as_bytes()).await;
        self.send(&body).await;
    }

    /// Reads until the header terminator; anything past it lands in
    /// `body_prefix`.
    pub async fn read_response_head(&mut self, deadline: Duration) -> RawResponse {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4096];
        let end = loop {
            if let Some(pos) = find_subslice(&buf, b"\r\n\r\n") {
                break pos;
            }
            let n = tokio::time::timeout(deadline, self.stream.read(&mut chunk))
                .await
                .expect("timed out reading response head")
                .expect("read response head");
            assert!(n > 0, "connection closed before response head completed");
            buf.extend_from_slice(&chunk[..n]);
        };
        let head = String::from_utf8_lossy(&buf[..end]).into_owned();
        let mut lines = head.split("\r\n");
        let status_line = lines.next().expect("status line");
        let status: u16 = status_line
            .split_whitespace()
            .nth(1)
            .expect("status code")
            .parse()
            .expect("numeric status");
        let headers = lines
            .filter_map(|line| {
                let (name, value) = line.split_once(':')?;
                Some((name.trim().to_ascii_lowercase(), value.trim().to_owned()))
            })
            .collect();
        RawResponse {
            status,
            headers,
            body_prefix: buf[end + 4..].to_vec(),
        }
    }

    /// One socket read (one arrival event). `None` on clean EOF.
    pub async fn read_some(&mut self, deadline: Duration) -> Option<Vec<u8>> {
        let mut chunk = [0u8; 16 * 1024];
        let n = tokio::time::timeout(deadline, self.stream.read(&mut chunk))
            .await
            .expect("timed out waiting for socket data")
            .expect("socket read");
        if n == 0 {
            None
        } else {
            Some(chunk[..n].to_vec())
        }
    }
}

pub fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

/// Decodes a COMPLETE HTTP/1.1 chunked body, returning `None` unless the
/// terminating zero-size chunk is present and every chunk is well-formed —
/// the clean-close assertion for streams.
pub fn dechunk(body: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut rest = body;
    loop {
        let line_end = find_subslice(rest, b"\r\n")?;
        let size_str = std::str::from_utf8(&rest[..line_end]).ok()?;
        let size = usize::from_str_radix(size_str.split(';').next()?.trim(), 16).ok()?;
        rest = &rest[line_end + 2..];
        if size == 0 {
            // Terminator: optional trailers then the final CRLF.
            return Some(out);
        }
        if rest.len() < size + 2 {
            return None; // truncated mid-chunk: NOT a clean close
        }
        out.extend_from_slice(&rest[..size]);
        if &rest[size..size + 2] != b"\r\n" {
            return None;
        }
        rest = &rest[size + 2..];
    }
}

// ---------------------------------------------------------------------
// v2 provider-script helpers (mirrors http_chat.rs)
// ---------------------------------------------------------------------

pub fn expect_v2_prepare(frame: DataFrame) -> (PrepareFrame, Bytes) {
    match frame {
        DataFrame::V2Prepare { frame, binary_body } => match *frame {
            FrameV2::Prepare(prepare) => (prepare, binary_body.expect("binary body present")),
            other => panic!("expected prepare frame, got {}", other.type_str()),
        },
        other => panic!("expected v2 prepare data frame, got {other:?}"),
    }
}

pub fn scope_with_lease(prepare: &PrepareFrame, lease: LeaseId) -> RequestScope {
    RequestScope {
        lease_id: Some(json_v2::LeaseId(*lease.as_bytes())),
        ..prepare.scope
    }
}

pub fn prepared_event(prepare: &PrepareFrame, lease: LeaseId, eta_ms: u64) -> AttemptEvent {
    AttemptEvent::Prepared {
        lease,
        ttl: Duration::from_secs(30),
        billable_prompt_tokens: 6,
        queue_depth: 0,
        prefill_can_start: true,
        frame: Box::new(PreparedFrame {
            scope: scope_with_lease(prepare, lease),
            ttl_ms: 30_000,
            billable_input_tokens: 6,
            resource: ResourceFacts::default(),
            execution: ExecutionFacts {
                engine_queue_depth: 0,
                prefill_can_start: true,
                predicted_first_content_ms: Some(eta_ms),
            },
        }),
    }
}

pub fn completed_terminal(
    scope: RequestScope,
    provider: &str,
    completion_tokens: u64,
    sequence: u64,
) -> TerminalFrame {
    TerminalFrame {
        scope,
        provider_id: provider.to_owned(),
        model_id: CONCRETE_MODEL.to_owned(),
        origin_session_epoch: json_v2::SessionEpoch(1),
        outcome: json_v2::TerminalOutcome::Completed,
        error_class: None,
        usage: TerminalUsage {
            prompt_tokens: 6,
            completion_tokens,
            reasoning_tokens: 0,
        },
        generated_tokens: completion_tokens,
        response_hash: json_v2::ResponseHash([7; 32]),
        checkpoint: RollingHashCheckpoint {
            sequence,
            cumulative_completion_tokens: completion_tokens,
            rolling_hash: json_v2::ResponseHash([8; 32]),
        },
        se_signature: "test-signature".to_owned(),
    }
}

pub fn expect_control_start(frame: ControlFrame) -> RequestScope {
    match frame {
        ControlFrame::V2(f) => match *f {
            FrameV2::Start(start) => start.scope,
            other => panic!("expected start, got {}", other.type_str()),
        },
        other => panic!("expected v2 control frame, got {other:?}"),
    }
}

pub fn new_lease() -> LeaseId {
    LeaseId::new(Uuid::new_v4())
}
