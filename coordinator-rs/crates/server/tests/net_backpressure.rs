//! Socket-level backpressure verification (plan §13.6, §14): a consumer
//! that stops reading its TCP socket must propagate backpressure all the
//! way back to a provider CANCEL, with bounded memory at every hop.
//!
//! The chain under test: stalled client socket → hyper stops polling the
//! SSE body stream (its write buffer is bounded) → the bounded consumer
//! event channel fills → `forward_chunk` observes `Full` → the reducer
//! gets `ConsumerPipeStalled` → cancel frame on the provider control lane.
//! Every intermediate is bounded (chunk pipe by items AND bytes, the
//! driver input channel, the consumer channel), so total acceptance before
//! the cancel is a fixed budget — asserted here.

#[path = "http_harness.rs"]
mod harness;
#[path = "net_support/mod.rs"]
mod net;

use std::time::Duration;

use darkbloom_protocol::json_v2::FrameV2;
use darkbloom_server::contracts::{AttemptEvent, ChunkFrame, ControlFrame, PipeError};
use darkbloom_server::serve::ServeOptions;

use harness::*;
use net::*;

/// Generous ceiling on bytes the coordinator may accept from the provider
/// after the client stalls: chunk pipe (128 KiB) + driver input channel +
/// consumer channel (256 × ~2 KiB) + hyper write buffer (~400 KiB) + both
/// socket buffers. Unbounded buffering would blow far past this.
const ACCEPTED_BYTES_CEILING: usize = 16 * 1024 * 1024;

#[tokio::test]
async fn stalled_consumer_socket_trips_provider_cancel_with_bounded_buffers() {
    let mut h = HarnessBuilder::new()
        .policy(|p| {
            p.pipe_max_items = 64;
            p.pipe_max_bytes = 128 * 1024;
        })
        .build();
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

        // Flood ~2 KiB content chunks as fast as the pipe accepts them,
        // reporting overflow like the real session reader does, until the
        // coordinator cancels this attempt. (Sealing once and resending the
        // same ciphertext is fine: chunks decrypt independently.)
        let plaintext = content_chunk(&"x".repeat(2048));
        let sealed = provider.seal_v2_chunk(&coordinator_public, plaintext.as_bytes());
        let mut sequence = 0u64;
        let mut accepted_bytes = 0usize;
        let mut push_timer = tokio::time::interval(Duration::from_millis(1));
        loop {
            tokio::select! {
                control = provider.receivers.control_rx.recv() => {
                    let (frame, on_wire) = control.expect("control lane open");
                    let _ = on_wire.send(Ok(()));
                    match frame {
                        ControlFrame::V2(f) => match *f {
                            FrameV2::Cancel(_) | FrameV2::Abort(_) => break,
                            other => panic!("unexpected control frame {}", other.type_str()),
                        },
                        other => panic!("unexpected control frame {other:?}"),
                    }
                }
                _ = push_timer.tick() => {
                    sequence += 1;
                    let frame = ChunkFrame {
                        payload: sealed.clone(),
                        sequence,
                        cumulative_tokens: sequence,
                    };
                    match attach.chunks.try_send(frame) {
                        Ok(()) => accepted_bytes += sealed.len(),
                        Err(PipeError::Full) => {
                            // Session-reader parity: report, never block.
                            let _ = attach.events.try_send(AttemptEvent::PipeOverflow);
                        }
                        Err(PipeError::Closed) => break,
                    }
                }
            }
        }
        accepted_bytes
    });

    let server = NetServer::spawn(h.router.clone(), ServeOptions::default()).await;
    let mut client = RawClient::connect(server.addr).await;
    client.send_chat(&chat_body(true)).await;
    let head = client.read_response_head(Duration::from_secs(10)).await;
    assert_eq!(head.status, 200);

    // Read a couple of arrivals to prove the stream is live, then STOP
    // reading while keeping the socket open — the stalled-consumer case.
    let _ = client.read_some(Duration::from_secs(10)).await;
    let _ = client.read_some(Duration::from_secs(10)).await;

    // The provider script resolves only when the cancel arrives.
    let accepted_bytes = tokio::time::timeout(Duration::from_secs(30), script)
        .await
        .expect("provider never received a cancel — backpressure did not propagate")
        .expect("provider script");
    println!("[backpressure] provider chunks accepted before cancel: {accepted_bytes} bytes");
    assert!(
        accepted_bytes < ACCEPTED_BYTES_CEILING,
        "coordinator accepted {accepted_bytes} bytes from the provider after the \
         consumer stalled — an intermediate buffer is unbounded",
    );

    // Unblock teardown: close the stalled socket, then stop the server.
    drop(client);
    h.shutdown.cancel();
    server.shutdown().await;
}
