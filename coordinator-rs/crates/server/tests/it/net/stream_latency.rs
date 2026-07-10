//! Socket-level SSE flush/latency verification (plan §15.4, §16: per-chunk
//! relay p99 < 2 ms — the coordinator must never ADD artificial stalls).
//!
//! A fake v2 provider pushes one content chunk every ~10 ms through real
//! session channels; a raw TCP client measures inter-chunk arrival gaps on
//! the wire. This pins the two failure modes the fix targets:
//!
//! - **Nagle stalls**: without TCP_NODELAY every small SSE frame waits for
//!   the previous segment's (delayed) ACK — chunks arrive in ~40 ms
//!   batches. The production serve loop (`darkbloom_server::serve`) sets
//!   NODELAY at accept; the test asserts per-chunk arrival granularity.
//! - **Body buffering**: if hyper/axum buffered the stream, all chunks
//!   would arrive at the end. The test asserts the client-observed span
//!   covers the provider's send span.
//!
//! The pre-fix posture (plain `axum::serve`) is measured too and printed
//! for comparison; assertions run only against the shipped loop.

use std::time::{Duration, Instant};

use darkbloom_protocol::json_v2::FrameV2;
use darkbloom_server::contracts::{AttemptEvent, ChunkFrame, ControlFrame};
use darkbloom_server::serve::ServeOptions;

use crate::support::http::*;
use crate::support::net::*;

const CHUNKS: usize = 40;
const SEND_INTERVAL: Duration = Duration::from_millis(10);

struct StreamStats {
    /// One entry per socket read that carried body bytes.
    arrivals: Vec<Instant>,
    body: Vec<u8>,
    head: RawResponse,
}

impl StreamStats {
    fn gaps_ms(&self) -> Vec<f64> {
        self.arrivals
            .windows(2)
            .map(|w| w[1].duration_since(w[0]).as_secs_f64() * 1_000.0)
            .collect()
    }

    fn span_ms(&self) -> f64 {
        match (self.arrivals.first(), self.arrivals.last()) {
            (Some(first), Some(last)) => last.duration_since(*first).as_secs_f64() * 1_000.0,
            _ => 0.0,
        }
    }

    fn print(&self, label: &str) {
        let gaps = self.gaps_ms();
        let mean = if gaps.is_empty() {
            0.0
        } else {
            gaps.iter().sum::<f64>() / gaps.len() as f64
        };
        let max = gaps.iter().cloned().fold(0.0f64, f64::max);
        println!(
            "[{label}] arrivals={} span={:.0}ms mean_gap={:.1}ms max_gap={:.1}ms",
            self.arrivals.len(),
            self.span_ms(),
            mean,
            max,
        );
    }
}

/// Boots one fresh harness + provider script and streams CHUNKS chunks at
/// SEND_INTERVAL through the given server, measuring raw-socket arrivals.
async fn stream_once(use_production_loop: bool) -> StreamStats {
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

        for i in 0..CHUNKS {
            let plaintext = content_chunk(&format!("tok{i:03}"));
            attach
                .chunks
                .try_send(ChunkFrame {
                    payload: provider.seal_v2_chunk(&coordinator_public, plaintext.as_bytes()),
                    sequence: (i + 1) as u64,
                    cumulative_tokens: (i + 1) as u64,
                })
                .expect("push chunk");
            tokio::time::sleep(SEND_INTERVAL).await;
        }

        let terminal = completed_terminal(
            scope_with_lease(&prepare, lease),
            "prov-lat",
            CHUNKS as u64,
            CHUNKS as u64,
        );
        attach
            .events
            .send(AttemptEvent::Terminal(Box::new(terminal)))
            .await
            .expect("send terminal");
        // Terminal ack after settle.
        match provider.expect_control().await {
            ControlFrame::V2(f) => match *f {
                FrameV2::TerminalAck(_) => {}
                other => panic!("expected terminal ack, got {}", other.type_str()),
            },
            other => panic!("expected terminal ack, got {other:?}"),
        }
    });

    let server = if use_production_loop {
        NetServer::spawn(h.router.clone(), ServeOptions::default()).await
    } else {
        NetServer::spawn_axum_baseline(h.router.clone()).await
    };

    let mut client = RawClient::connect(server.addr).await;
    client.send_chat(&chat_body(true)).await;
    let head = client.read_response_head(Duration::from_secs(10)).await;
    assert_eq!(head.status, 200);

    let mut body = head.body_prefix.clone();
    let mut arrivals = Vec::new();
    if !body.is_empty() {
        arrivals.push(Instant::now());
    }
    while find_subslice(&body, b"data: [DONE]").is_none() {
        let data = client
            .read_some(Duration::from_secs(10))
            .await
            .expect("stream ended before [DONE]");
        arrivals.push(Instant::now());
        body.extend_from_slice(&data);
    }

    script.await.expect("provider script");
    server.shutdown().await;
    StreamStats {
        arrivals,
        body,
        head,
    }
}

#[tokio::test]
async fn sse_flushes_every_chunk_immediately_no_nagle_no_buffering() {
    // Inter-chunk-gap assertions are wall-clock sensitive: serialize away
    // from concurrent suite load instead of loosening the thresholds.
    let _timing = crate::support::timing_lock().await;
    // Informational pre-fix baseline (plain axum::serve, no NODELAY).
    let baseline = stream_once(false).await;
    baseline.print("baseline axum::serve");

    // The shipped serve loop — asserted.
    let fixed = stream_once(true).await;
    fixed.print("production serve loop");

    // Streaming posture headers (chat.rs module docs).
    let head = &fixed.head;
    assert_eq!(head.header("content-type"), Some("text/event-stream"));
    assert_eq!(head.header("cache-control"), Some("no-cache, no-store"));
    assert_eq!(head.header("x-accel-buffering"), Some("no"));
    assert_eq!(head.header("transfer-encoding"), Some("chunked"));
    assert_eq!(
        head.header("content-length"),
        None,
        "a streaming response must never carry Content-Length"
    );

    // Every provider chunk plus the usage chunk and [DONE] made it through,
    // and the chunked framing is complete.
    let payload = dechunk(&fixed.body).expect("chunked body must terminate cleanly");
    for i in 0..CHUNKS {
        let token = format!("tok{i:03}");
        assert!(
            find_subslice(&payload, token.as_bytes()).is_some(),
            "missing chunk {token}"
        );
    }

    // No wholesale batching: chunks sent 10 ms apart arrive as (mostly)
    // individual socket reads. Nagle batching collapses this to ~one read
    // per 40 ms delayed-ACK window; full buffering collapses it to one.
    let expected_events = CHUNKS + 2; // chunks + usage + [DONE]
    assert!(
        fixed.arrivals.len() >= expected_events * 6 / 10,
        "only {} arrival events for {} SSE events — stream is being batched",
        fixed.arrivals.len(),
        expected_events,
    );

    // No artificial stalls: nothing remotely near a Nagle/buffer pause.
    let max_gap = fixed.gaps_ms().iter().cloned().fold(0.0f64, f64::max);
    assert!(
        max_gap < 500.0,
        "inter-chunk stall of {max_gap:.1} ms observed"
    );

    // Not buffered-then-dumped: client-observed span covers at least half
    // the provider send span.
    let send_span_ms = (CHUNKS as f64) * SEND_INTERVAL.as_secs_f64() * 1_000.0;
    assert!(
        fixed.span_ms() >= send_span_ms * 0.5,
        "stream span {:.0} ms vs send span {send_span_ms:.0} ms — chunks were buffered",
        fixed.span_ms(),
    );
}
