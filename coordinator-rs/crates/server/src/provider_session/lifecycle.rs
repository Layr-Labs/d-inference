//! Session lifecycle: registration handshake, fleet connect, and the
//! writer/reader wiring for one accepted provider WebSocket (plan §7.4).
//! Invariant: reader exit is authoritative teardown — every attached
//! attempt observes `SessionLost` and the fleet hears `Disconnect{epoch}`.

use axum::extract::ws::WebSocket;
use futures::StreamExt;
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

use crate::contracts::{self, ConnectAccept, FleetCommand, SessionSeed};

use super::deps::{SessionContext, SessionDeps};
use super::{attempts, reader, registration, writer};

/// Serves one upgraded provider WebSocket to completion. Never panics; all
/// failure paths tear the session down and (post-connect) notify the fleet.
pub async fn serve(socket: WebSocket, deps: SessionDeps) {
    let mut socket = socket;
    let outcome = match registration::register(&mut socket, &deps).await {
        Ok(outcome) => outcome,
        Err(err) => {
            tracing::info!(error = %err, "provider registration failed");
            let _ = socket.send(axum::extract::ws::Message::Close(None)).await;
            return;
        }
    };

    let provider = outcome.summary.provider;
    let seed = SessionSeed {
        protocol: outcome.summary.protocol,
        lane_caps: deps.config.lane_caps,
    };
    let (reply_tx, reply_rx) = oneshot::channel();
    let connect = FleetCommand::Connect {
        registration: Box::new(outcome.summary.clone()),
        session_seed: Box::new(seed),
        reply: reply_tx,
    };
    if deps.fleet.commands.send(connect).await.is_err() {
        tracing::warn!(provider = %provider, "fleet unavailable at connect");
        return;
    }
    let accept: ConnectAccept = match reply_rx.await {
        Ok(Ok(accept)) => accept,
        Ok(Err(rejected)) => {
            tracing::warn!(provider = %provider, error = %rejected, "connect rejected");
            let _ = socket.send(axum::extract::ws::Message::Close(None)).await;
            return;
        }
        Err(_) => return,
    };

    // Registration evidence becomes the first epoch-fenced trust verdict.
    let verdict_cmd = FleetCommand::TrustVerdict {
        provider,
        trust_epoch: outcome.verdict.trust_epoch,
        verdict: outcome.verdict.verdict.clone(),
    };
    if deps.fleet.commands.send(verdict_cmd).await.is_err() {
        return;
    }

    let ctx = SessionContext {
        provider,
        epoch: accept.epoch,
        protocol: outcome.summary.protocol,
        provider_x25519_b64: outcome.summary.public_key_b64.clone(),
        se_public_key: outcome.verdict.se_public_key.clone(),
        statics: outcome.statics,
    };

    run_session(socket, deps, ctx, accept).await;
}

/// Wires the writer task and reader loop for one accepted session and joins
/// them; on return the fleet has been told `Disconnect{epoch}`.
async fn run_session(
    socket: WebSocket,
    deps: SessionDeps,
    ctx: SessionContext,
    accept: ConnectAccept,
) {
    let provider = ctx.provider;
    let epoch = ctx.epoch;
    let cancel = CancellationToken::new();
    let attempts = attempts::shared();
    let (sink, stream) = socket.split();

    // Session-originated frames (challenges, zombie cancels, test acks) ride
    // an internal lane with the same control-class priority; the session
    // never holds its own SessionHandle, so fleet-side handle drop is the
    // complete fence signal.
    let (internal_tx, internal_rx) = mpsc::channel::<writer::SessionWrite>(64);

    let contracts::SessionReceivers {
        control_rx,
        data_rx,
        command_rx,
    } = accept.receivers;

    let writer_task = tokio::spawn(writer::run_writer(writer::WriterInputs {
        sink,
        control_rx,
        data_rx,
        internal_rx,
        attempts: attempts.clone(),
        cancel: cancel.clone(),
        write_timeout: deps.config.write_timeout,
    }));

    let reader = reader::Reader::new(
        stream,
        command_rx,
        internal_tx,
        attempts.clone(),
        ctx,
        deps.clone(),
        cancel.clone(),
    );
    reader.run().await;

    // Reader exit is authoritative teardown: stop the writer, fail every
    // attached attempt, and report the (possibly stale) disconnect.
    cancel.cancel();
    let _ = writer_task.await;

    let orphaned = attempts::take_all_sinks(&attempts);
    for (sinks, reserved) in orphaned {
        // A full lane cannot swallow the mandatory SessionLost: fall back
        // to the permit reserved at attach (plan §9.4.5).
        if sinks
            .events
            .try_send(contracts::AttemptEvent::SessionLost)
            .is_err()
        {
            if let Some(permit) = reserved {
                let _ = permit.send(contracts::AttemptEvent::SessionLost);
            }
        }
    }
    let _ = deps
        .fleet
        .commands
        .send(FleetCommand::Disconnect { provider, epoch })
        .await;
    tracing::info!(provider = %provider, epoch = epoch.get(), "provider session ended");
}
