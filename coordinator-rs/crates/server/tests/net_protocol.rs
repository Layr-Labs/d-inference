//! Socket-level protocol-posture verification (plan §14, §15.1): what the
//! coordinator actually negotiates and enforces on a plaintext socket, the
//! way it runs behind Caddy in production.
//!
//! Covered here:
//! - HTTP/1.1 keep-alive (Caddy's default upstream transport),
//! - h2c prior-knowledge acceptance (Caddy `versions h2c` keeps working),
//! - the armed header-read timeout (slowloris),
//! - concurrency shed BEFORE body collection (plan §14),
//! - graceful shutdown ending an in-flight SSE stream with a clean
//!   chunked-body termination (never a mid-event cut),
//! - provider WebSocket message/frame caps sized for sealed vision
//!   payloads (32 MiB single-frame messages must pass).

#[path = "http_harness.rs"]
mod harness;
#[path = "net_support/mod.rs"]
mod net;

use std::sync::Arc;
use std::time::{Duration, Instant};

use futures::{SinkExt, StreamExt};

use darkbloom_server::contracts::AttemptEvent;
use darkbloom_server::http::{build_router_with, HttpConfig, ProviderConnectHandler};
use darkbloom_server::serve::ServeOptions;

use harness::*;
use net::*;

// ---------------------------------------------------------------------
// HTTP/1.1 keep-alive
// ---------------------------------------------------------------------

#[tokio::test]
async fn http1_keepalive_serves_sequential_requests_on_one_connection() {
    let h = HarnessBuilder::new().build();
    let server = NetServer::spawn(h.router.clone(), ServeOptions::default()).await;
    let mut client = RawClient::connect(server.addr).await;

    // Second round doubles as the Caddy health-probe path check: the prod
    // Caddyfile probes `health_uri /health`, so that alias must be 200.
    for (round, path) in ["/healthz", "/health"].into_iter().enumerate() {
        client
            .send(format!("GET {path} HTTP/1.1\r\nHost: t\r\n\r\n").as_bytes())
            .await;
        let head = client.read_response_head(Duration::from_secs(5)).await;
        assert_eq!(head.status, 200, "request {round} on the same connection");
        // Consume the fixed-length body ("ok") before reusing the socket.
        let len: usize = head
            .header("content-length")
            .expect("length")
            .parse()
            .unwrap();
        let mut got = head.body_prefix.len();
        while got < len {
            got += client
                .read_some(Duration::from_secs(5))
                .await
                .expect("body")
                .len();
        }
    }
    server.shutdown().await;
}

// ---------------------------------------------------------------------
// h2c prior knowledge
// ---------------------------------------------------------------------

#[tokio::test]
async fn h2c_prior_knowledge_is_accepted_on_plaintext() {
    let h = HarnessBuilder::new().build();
    let server = NetServer::spawn(h.router.clone(), ServeOptions::default()).await;
    let mut client = RawClient::connect(server.addr).await;

    // HTTP/2 connection preface + an empty SETTINGS frame.
    client.send(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").await;
    client
        .send(&[0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00])
        .await;

    // A server speaking h2c answers with its own SETTINGS frame (type 0x04);
    // an HTTP/1.1-only server would send a 4xx or close.
    let mut reply = Vec::new();
    while reply.len() < 9 {
        let data = client
            .read_some(Duration::from_secs(5))
            .await
            .expect("connection closed instead of h2c handshake");
        reply.extend_from_slice(&data);
    }
    assert_eq!(reply[3], 0x04, "expected an HTTP/2 SETTINGS frame");
    server.shutdown().await;
}

// ---------------------------------------------------------------------
// Slowloris: header read timeout
// ---------------------------------------------------------------------

#[tokio::test]
async fn header_read_timeout_closes_slowloris_connections() {
    let h = HarnessBuilder::new().build();
    let server = NetServer::spawn(
        h.router.clone(),
        ServeOptions {
            header_read_timeout: Duration::from_millis(500),
        },
    )
    .await;

    let mut slow = RawClient::connect(server.addr).await;
    // A partial request line and then silence.
    slow.send(b"POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\n")
        .await;
    let started = Instant::now();
    // The server must hang up (possibly after an error response); without
    // the armed timer this read blocks forever and the test times out.
    while let Some(_bytes) = slow.read_some(Duration::from_secs(3)).await {}
    let elapsed = started.elapsed();
    println!("[slowloris] connection closed after {elapsed:?}");
    assert!(
        elapsed < Duration::from_secs(3),
        "slowloris connection survived {elapsed:?}"
    );

    // The server itself stays healthy.
    let mut ok = RawClient::connect(server.addr).await;
    ok.send(b"GET /healthz HTTP/1.1\r\nHost: t\r\n\r\n").await;
    assert_eq!(
        ok.read_response_head(Duration::from_secs(5)).await.status,
        200
    );
    server.shutdown().await;
}

// ---------------------------------------------------------------------
// Concurrency shed BEFORE body collection (plan §14)
// ---------------------------------------------------------------------

#[tokio::test]
async fn concurrency_shed_rejects_before_reading_the_body() {
    let mut h = HarnessBuilder::new().build();
    // One global slot so the second request is guaranteed to shed.
    let router = build_router_with(
        h.state.clone(),
        HttpConfig {
            global_concurrency: 1,
            per_account_concurrency: 1,
            shutdown: h.shutdown.clone(),
            request_tracker: h.request_tracker.clone(),
            ..Default::default()
        },
    );
    let server = NetServer::spawn(router, ServeOptions::default()).await;

    // Request A occupies the only slot: the provider accepts the dispatch
    // and then stalls, keeping A pending on first content.
    let mut provider = h.providers.remove(0);
    let hold = tokio::spawn(async move {
        let attach = provider.expect_attach().await;
        let (_prepare, _body) = expect_v2_prepare(provider.expect_data().await);
        // Hold the attach (and with it the request) until the test ends.
        tokio::time::sleep(Duration::from_secs(30)).await;
        drop(attach);
    });
    let mut client_a = RawClient::connect(server.addr).await;
    client_a.send_chat(&chat_body(true)).await;
    // A holds its permits from header time; give it a moment to acquire.
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Request B declares a large body but sends almost none of it. The
    // shed must arrive from the HEADERS alone — if the handler collected
    // the body before checking limits, this would hang for the full body
    // timeout instead of answering promptly.
    let mut client_b = RawClient::connect(server.addr).await;
    client_b
        .send(
            b"POST /v1/chat/completions HTTP/1.1\r\nHost: t\r\n\
              Authorization: Bearer sk-test-token\r\n\
              Content-Type: application/json\r\nContent-Length: 1000000\r\n\r\n{\"mo",
        )
        .await;
    let started = Instant::now();
    let head = client_b.read_response_head(Duration::from_secs(5)).await;
    println!(
        "[shed-before-body] 429 after {:?} with body incomplete",
        started.elapsed()
    );
    assert_eq!(head.status, 429, "expected the concurrency shed");
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "shed took {:?} — the body was being collected first",
        started.elapsed()
    );

    hold.abort();
    h.shutdown.cancel();
    server.shutdown().await;
}

// ---------------------------------------------------------------------
// Graceful shutdown: in-flight SSE ends with a clean chunked close
// ---------------------------------------------------------------------

#[tokio::test]
async fn graceful_shutdown_ends_streams_with_clean_chunked_termination() {
    let mut h = HarnessBuilder::new().build();
    let mut provider = h.providers.remove(0);
    let coordinator_public = h.coordinator_public.clone();

    let script = tokio::spawn(async move {
        let attach = provider.expect_attach().await;
        let (prepare, _body) = expect_v2_prepare(provider.expect_data().await);
        let lease = new_lease();
        attach
            .events
            .send(prepared_event(&prepare, lease, 30))
            .await
            .expect("send prepared");
        let _ = expect_control_start(provider.expect_control().await);
        attach
            .events
            .send(AttemptEvent::Started)
            .await
            .expect("send started");
        attach
            .chunks
            .try_send(darkbloom_server::contracts::ChunkFrame {
                payload: provider
                    .seal_v2_chunk(&coordinator_public, content_chunk("mid").as_bytes()),
                sequence: 1,
                cumulative_tokens: 1,
            })
            .expect("push chunk");
        // The shutdown-driven cancel; the provider goes silent afterwards
        // and the bounded evidence timers finish the task.
        let _ = provider.expect_control().await;
    });

    let server = NetServer::spawn(h.router.clone(), ServeOptions::default()).await;
    let mut client = RawClient::connect(server.addr).await;
    client.send_chat(&chat_body(true)).await;
    let head = client.read_response_head(Duration::from_secs(10)).await;
    assert_eq!(head.status, 200);

    // First committed chunk on the wire, then shut down mid-stream the way
    // bootstrap does: request tasks first, then the HTTP layer.
    let mut body = head.body_prefix.clone();
    while find_subslice(&body, b"data: ").is_none() {
        body.extend(
            client
                .read_some(Duration::from_secs(10))
                .await
                .expect("first chunk"),
        );
    }
    h.shutdown.cancel();
    server.stop.cancel();

    // Drain to EOF: the stream must end with a complete chunked body —
    // a terminating zero-chunk, never a connection cut mid-event.
    while let Some(data) = client.read_some(Duration::from_secs(10)).await {
        body.extend_from_slice(&data);
    }
    let payload = dechunk(&body).expect("chunked body did not terminate cleanly");
    assert!(
        payload.ends_with(b"\n\n"),
        "stream cut mid-SSE-event: {:?}",
        String::from_utf8_lossy(&payload)
    );

    script.await.expect("provider script");
    let _ = server.task.await;
}

// ---------------------------------------------------------------------
// Provider WebSocket: 32 MiB single-frame messages must pass
// ---------------------------------------------------------------------

#[tokio::test]
async fn websocket_accepts_full_size_single_frame_messages() {
    let h = HarnessBuilder::new().build();

    // Echo handler standing in for provider_session::serve — this test
    // exercises the UPGRADE configuration (message and frame caps), not
    // the session protocol.
    let connect: ProviderConnectHandler = Arc::new(|mut socket| {
        Box::pin(async move {
            while let Some(Ok(message)) = socket.recv().await {
                if let axum::extract::ws::Message::Binary(data) = message {
                    let reply = format!("{}", data.len());
                    if socket
                        .send(axum::extract::ws::Message::Text(reply.into()))
                        .await
                        .is_err()
                    {
                        return;
                    }
                }
            }
        })
    });
    let router = build_router_with(
        h.state.clone(),
        HttpConfig {
            provider_connect: Some(connect),
            ..Default::default()
        },
    );
    let server = NetServer::spawn(router, ServeOptions::default()).await;

    let (mut ws, _resp) =
        tokio_tungstenite::connect_async(format!("ws://{}/v1/providers/connect", server.addr))
            .await
            .expect("websocket upgrade");

    // 20 MiB in ONE frame: over tungstenite's 16 MiB default frame cap,
    // under the 32 MiB sealed-vision message cap. The server must accept
    // it — which requires max_frame_size to be raised alongside
    // max_message_size at the upgrade.
    let payload = vec![0xAB_u8; 20 * 1024 * 1024];
    ws.send(tokio_tungstenite::tungstenite::Message::Binary(payload))
        .await
        .expect("send 20 MiB frame");

    let reply = tokio::time::timeout(Duration::from_secs(15), ws.next())
        .await
        .expect("timed out waiting for echo")
        .expect("connection closed — the frame was rejected")
        .expect("websocket error — the frame was rejected");
    assert_eq!(
        reply.into_text().expect("text reply"),
        (20 * 1024 * 1024).to_string()
    );

    let _ = ws.close(None).await;
    let mut stream = ws;
    // Drain the close handshake so the server side finishes cleanly.
    while let Some(Ok(_)) = stream.next().await {}
    drop(stream);
    server.shutdown().await;
}
