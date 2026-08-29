//! The settle/release/review effect family: durable terminal dispositions
//! through the ledger facade (plan §12.6–§12.8).
//! Invariant: money moves only through these ledger calls; every failure
//! path escalates to review or leaves the job to the recovery sweepers.

use darkbloom_core::ids::SessionEpoch;
use darkbloom_core::money::Tokens;
use darkbloom_core::request::Event;
use darkbloom_protocol::json_v2::AckDisposition;

use crate::contracts::ProtocolGen;
use crate::request_task::funding::clamp_tokens;
use crate::request_task::terminal::settle_params;

use super::Driver;

impl Driver {
    pub(super) async fn settle(
        &mut self,
        attempt: darkbloom_core::ids::AttemptId,
        accepted_checkpoint: Tokens,
    ) {
        let Some(runtime) = self.runtimes.get(&attempt) else {
            self.fatal = true;
            return;
        };
        let Some(receipt) = &runtime.receipt else {
            self.fatal = true;
            return;
        };
        // v2 terminals carry the epoch the attempt RAN under; v1 has no
        // origin field, so the dispatch session is the origin (plan §9.1.3).
        let origin_session_epoch = match receipt {
            crate::request_task::terminal::TerminalReceipt::V2 { frame, .. } => {
                SessionEpoch::new(frame.origin_session_epoch.0)
            }
            _ => runtime.session.epoch,
        };
        // v1 prompt billing basis is the frozen estimate (module docs): the
        // provider's self-reported count is receipt/audit material only.
        let frozen_prompt_override = (runtime.protocol == ProtocolGen::V1)
            .then(|| clamp_tokens(self.req.estimated_prompt_tokens));
        let params = settle_params(&crate::request_task::terminal::SettleInputs {
            job: self.req.job,
            attempt,
            receipt,
            accepted_sequence: runtime.accepted_sequence,
            accepted_checkpoint,
            frozen_prompt_override,
            origin_session_epoch,
            coordinator_epoch: self.deps.coordinator_epoch,
        });
        let usage = receipt.usage_out();
        let ack =
            if let crate::request_task::terminal::TerminalReceipt::V2 { frame, digest } = receipt {
                Some((frame.scope, *digest))
            } else {
                None
            };
        match self.deps.ledger.settle(params).await {
            Ok(_) => {
                self.usage_out = Some(usage);
                // ACK only after the durable disposition commit (plan §12.8).
                if let (Some((scope, digest)), Some(runtime)) = (ack, self.runtimes.get(&attempt)) {
                    let frame = runtime.terminal_ack_frame(scope, digest, AckDisposition::Recorded);
                    if runtime.session.submit_control(frame).is_err() {
                        tracing::debug!(job = %self.req.job, "terminal ack submit failed; provider will replay");
                    }
                }
                self.push(Event::SettlementRecorded);
            }
            Err(err) => {
                tracing::warn!(job = %self.req.job, %err, "settlement failed; escalating to review");
                self.ledger_error = Some(err);
                self.move_to_review("settlement_failed".to_owned()).await;
            }
        }
    }

    pub(super) async fn release_job(&mut self) {
        let reason = self
            .outcome
            .map(|o| format!("{o:?}"))
            .unwrap_or_else(|| "released".to_owned());
        let params = crate::request_task::funding::release_params(
            self.req.job,
            &reason,
            self.deps.coordinator_epoch,
        );
        match self.deps.ledger.release(params).await {
            Ok(()) => self.push(Event::ReleaseRecorded),
            Err(err) => {
                tracing::warn!(job = %self.req.job, %err, "release failed; escalating to review");
                self.ledger_error = Some(err);
                self.move_to_review("release_failed".to_owned()).await;
            }
        }
    }

    pub(super) async fn move_to_review(&mut self, reason: String) {
        match self.deps.ledger.move_to_review(self.req.job, reason).await {
            Ok(()) => self.push(Event::ReviewRecorded),
            Err(err) => {
                // Every durable path failed: leave the reservation held for
                // the recovery sweepers (plan §18.1) and stop the task.
                tracing::error!(job = %self.req.job, %err, "review escalation failed; leaving job to recovery");
                self.fatal = true;
            }
        }
    }
}
