//! Socket-level test support for the `net` suite: a real server on an
//! ephemeral port (through the SHIPPED `darkbloom_server::serve` loop) and
//! a raw TCP HTTP/1.1 client (no client library — the tests must observe
//! the exact bytes and timing on the wire). The v2 provider-script helpers
//! shared with the chat suites live in `crate::support::http`.

use std::net::SocketAddr;
use std::time::Duration;

use axum::Router;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_util::sync::CancellationToken;

use darkbloom_server::serve::{serve, ServeOptions};

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
