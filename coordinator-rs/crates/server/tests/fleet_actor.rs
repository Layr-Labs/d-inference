//! FleetActor tests driven purely through the frozen mailbox contract
//! (plan §7.3, §9.1, §10.7, §11): connect/admit/exclusion, permit release
//! idempotency, revision-fenced presence, trust-epoch fencing, and online
//! calibration.

use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwap;
use tokio::sync::oneshot;

use darkbloom_core::fleet::admission::{
    AdmissionConfig, CandidateSnapshot, GateFailure, RejectionReason, RequestTraits,
};
use darkbloom_core::fleet::calibration::RatioPerMille;
use darkbloom_core::fleet::health::{HealthState, SecurityFence};
use darkbloom_core::fleet::model_presence::ModelPresence;
use darkbloom_core::ids::{JobId, ModelId, ProviderId, SessionEpoch, StateRevision, TrustEpoch};
use darkbloom_core::money::{MicroUsd, Tokens};
use darkbloom_core::time::DurationMs;
use darkbloom_server::contracts::{
    fleet_channels, AdmitOutcome, AdmitRequest, CatalogSnapshot, ConnectAccept, FleetCommand,
    FleetHandle, FleetObservation, HeartbeatUpdate, PriceCard, ProtocolGen, RegistrationSummary,
    SessionLaneCaps, SessionSeed, TrustVerdict,
};
use darkbloom_server::fleet::{self, permit_id_for, FleetConfig, FleetRuntime, FleetTunables};

const MODEL: &str = "concrete-build";
const ALIAS: &str = "public-model";

struct Rig {
    fleet: FleetHandle,
    runtime: FleetRuntime,
}

async fn start() -> Rig {
    let catalog = Arc::new(ArcSwap::from_pointee(CatalogSnapshot {
        version: 1,
        aliases: [(ALIAS.to_owned(), MODEL.to_owned())].into_iter().collect(),
        prices: [(
            MODEL.to_owned(),
            PriceCard {
                prompt_micro_per_token: MicroUsd::new(5),
                completion_micro_per_token: MicroUsd::new(17),
            },
        )]
        .into_iter()
        .collect(),
    }));
    let (fleet_handle, receivers) = fleet_channels(64, 64);
    let runtime = fleet::spawn(FleetConfig {
        receivers,
        admission: AdmissionConfig::default(),
        catalog,
        cancel: tokio_util::sync::CancellationToken::new(),
        tunables: FleetTunables::default(),
    });
    Rig {
        fleet: fleet_handle,
        runtime,
    }
}

fn provider(n: u128) -> ProviderId {
    ProviderId::new(uuid::Uuid::from_u128(n))
}

fn registration(id: ProviderId) -> RegistrationSummary {
    RegistrationSummary {
        provider: id,
        wire_identity: format!("serial:TEST-{id}"),
        protocol: ProtocolGen::V1,
        version: "0.8.0".to_owned(),
        public_key_b64: "pk".to_owned(),
        models: vec![ModelId::new(MODEL)],
        beneficiary: None,
        capabilities: vec!["hw_class:test".to_owned()],
    }
}

async fn connect(rig: &Rig, id: ProviderId) -> ConnectAccept {
    let (tx, rx) = oneshot::channel();
    rig.fleet
        .commands
        .send(FleetCommand::Connect {
            registration: Box::new(registration(id)),
            session_seed: Box::new(SessionSeed {
                protocol: ProtocolGen::V1,
                lane_caps: SessionLaneCaps::default(),
            }),
            reply: tx,
        })
        .await
        .expect("actor alive");
    rx.await.expect("reply").expect("connect accepted")
}

async fn trust(rig: &Rig, id: ProviderId, epoch: u64, verdict: TrustVerdict) {
    rig.fleet
        .commands
        .send(FleetCommand::TrustVerdict {
            provider: id,
            trust_epoch: TrustEpoch::new(epoch),
            verdict,
        })
        .await
        .expect("actor alive");
}

fn advisory_candidate(id: ProviderId, max_permits: u32, predicted_ms: u64) -> CandidateSnapshot {
    CandidateSnapshot {
        provider: id,
        session_current: true,
        trusted: true,
        challenge_fresh: true,
        runtime_integrity: true,
        model_presence: ModelPresence::NotPresent,
        supports_vision: false,
        supports_tools: true,
        supports_media: false,
        beneficiary: None,
        health: HealthState::Healthy,
        security: SecurityFence::Clear,
        data_lane_headroom: true,
        control_lane_headroom: true,
        outstanding_permits: 0,
        max_outstanding_permits: max_permits,
        advisory_capacity_ok: true,
        predicted_first_content: DurationMs::new(predicted_ms),
        decode_tokens_per_sec: 50,
        calibration: RatioPerMille::UNIT,
    }
}

async fn heartbeat(rig: &Rig, id: ProviderId, epoch: SessionEpoch, revision: u64, ready: bool) {
    heartbeat_shaped(rig, id, epoch, revision, ready, 4, 1_000).await;
}

async fn heartbeat_shaped(
    rig: &Rig,
    id: ProviderId,
    epoch: SessionEpoch,
    revision: u64,
    ready: bool,
    max_permits: u32,
    predicted_ms: u64,
) {
    rig.fleet
        .heartbeats
        .send(HeartbeatUpdate {
            provider: id,
            epoch,
            revision: StateRevision::new(revision),
            candidate: advisory_candidate(id, max_permits, predicted_ms),
            models: vec![(ModelId::new(MODEL), ready)],
        })
        .await
        .expect("actor alive");
}

fn request(model: &str, job: JobId, exclude: Vec<ProviderId>) -> AdmitRequest {
    AdmitRequest {
        job,
        model: ModelId::new(model),
        traits: RequestTraits {
            model: ModelId::new(model),
            needs_vision: false,
            needs_tools: false,
            needs_media: false,
            paid: false,
            expected_output_tokens: Tokens::new(100),
        },
        estimated_prompt_tokens: 64,
        requested_max_tokens: 256,
        exclude,
        paid: false,
    }
}

/// Admission retries briefly: heartbeats reduce asynchronously.
async fn admit_until_grant(
    rig: &Rig,
    model: &str,
    exclude: Vec<ProviderId>,
) -> Box<darkbloom_server::contracts::AdmitGrant> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let job = JobId::new(uuid::Uuid::new_v4());
        match rig
            .fleet
            .admit(request(model, job, exclude.clone()))
            .await
            .expect("actor alive")
        {
            AdmitOutcome::Grant(grant) => return grant,
            other => {
                assert!(
                    tokio::time::Instant::now() < deadline,
                    "never granted; last: {other:?}",
                    other = kind(&other)
                );
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        }
    }
}

fn kind(outcome: &AdmitOutcome) -> String {
    match outcome {
        AdmitOutcome::Grant(_) => "grant".into(),
        AdmitOutcome::RetryAfter { reason, .. } => format!("retry:{reason}"),
        AdmitOutcome::Reject(reason) => format!("reject:{reason:?}"),
    }
}

#[tokio::test]
async fn admit_resolves_alias_grants_price_and_excludes() {
    let rig = start().await;
    let p1 = provider(1);
    let p2 = provider(2);
    let a1 = connect(&rig, p1).await;
    let a2 = connect(&rig, p2).await;
    trust(&rig, p1, 1, TrustVerdict::SelfSigned).await;
    trust(&rig, p2, 2, TrustVerdict::SelfSigned).await;
    heartbeat(&rig, p1, a1.epoch, 1, true).await;
    heartbeat(&rig, p2, a2.epoch, 1, true).await;

    // Alias resolves to the concrete build and carries the price card.
    let grant = admit_until_grant(&rig, ALIAS, vec![]).await;
    assert_eq!(grant.concrete_model.as_str(), MODEL);
    assert_eq!(grant.price.prompt_micro_per_token, MicroUsd::new(5));
    assert_eq!(grant.price.completion_micro_per_token, MicroUsd::new(17));

    // Exclusion: shutting out one provider forces the other.
    let grant = admit_until_grant(&rig, ALIAS, vec![p1]).await;
    assert_eq!(grant.provider, p2);
    let grant = admit_until_grant(&rig, ALIAS, vec![p2]).await;
    assert_eq!(grant.provider, p1);

    // Excluding both leaves only transient failures: retry, never reject.
    let outcome = rig
        .fleet
        .admit(request(
            ALIAS,
            JobId::new(uuid::Uuid::new_v4()),
            vec![p1, p2],
        ))
        .await
        .expect("actor alive");
    assert!(
        matches!(outcome, AdmitOutcome::RetryAfter { .. }),
        "got {}",
        kind(&outcome)
    );

    rig.runtime.shutdown().await;
    drop(a1);
    drop(a2);
}

#[tokio::test]
async fn permit_release_is_idempotent_and_regates_admission() {
    let rig = start().await;
    let p1 = provider(10);
    let accept = connect(&rig, p1).await;
    trust(&rig, p1, 1, TrustVerdict::SelfSigned).await;
    // Advisory bound of exactly one outstanding prepare.
    heartbeat_shaped(&rig, p1, accept.epoch, 1, true, 1, 1_000).await;

    let job = JobId::new(uuid::Uuid::new_v4());
    let outcome = rig
        .fleet
        .admit(request(ALIAS, job, vec![]))
        .await
        .expect("actor alive");
    let grant = match outcome {
        AdmitOutcome::Grant(grant) => grant,
        other => {
            // Heartbeat may still be in flight; settle then grant.
            let _ = other;
            tokio::time::sleep(Duration::from_millis(50)).await;
            match rig.fleet.admit(request(ALIAS, job, vec![])).await.unwrap() {
                AdmitOutcome::Grant(grant) => grant,
                other => panic!("expected grant, got {}", kind(&other)),
            }
        }
    };
    assert_eq!(grant.provider, p1);

    // Saturated at one outstanding permit.
    let outcome = rig
        .fleet
        .admit(request(ALIAS, JobId::new(uuid::Uuid::new_v4()), vec![]))
        .await
        .expect("actor alive");
    assert!(
        matches!(outcome, AdmitOutcome::RetryAfter { .. }),
        "expected saturation, got {}",
        kind(&outcome)
    );

    // Release twice: idempotent, and capacity returns exactly once.
    let permit = permit_id_for(job, p1);
    for _ in 0..2 {
        rig.fleet
            .commands
            .send(FleetCommand::ReleasePermit {
                provider: p1,
                permit,
            })
            .await
            .expect("actor alive");
    }
    let grant = admit_until_grant(&rig, ALIAS, vec![]).await;
    assert_eq!(grant.provider, p1);

    rig.runtime.shutdown().await;
    drop(accept);
}

#[tokio::test]
async fn model_gone_fences_stale_heartbeat_by_revision() {
    let rig = start().await;
    let p1 = provider(20);
    let accept = connect(&rig, p1).await;
    trust(&rig, p1, 1, TrustVerdict::SelfSigned).await;

    heartbeat(&rig, p1, accept.epoch, 1, true).await;
    let _ = admit_until_grant(&rig, ALIAS, vec![]).await;

    // model_gone at revision 3.
    rig.fleet
        .commands
        .send(FleetCommand::ModelLifecycle {
            provider: p1,
            epoch: accept.epoch,
            model: ModelId::new(MODEL),
            ready: false,
            revision: StateRevision::new(3),
        })
        .await
        .expect("actor alive");

    // A delayed heartbeat from revision 2 claims the model is ready — it
    // must be fenced (plan §10.7), so admission keeps returning retry.
    heartbeat(&rig, p1, accept.epoch, 2, true).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let outcome = rig
        .fleet
        .admit(request(ALIAS, JobId::new(uuid::Uuid::new_v4()), vec![]))
        .await
        .expect("actor alive");
    assert!(
        matches!(outcome, AdmitOutcome::RetryAfter { .. }),
        "stale heartbeat resurrected a gone model: {}",
        kind(&outcome)
    );

    // A genuinely newer heartbeat restores readiness.
    heartbeat(&rig, p1, accept.epoch, 4, true).await;
    let grant = admit_until_grant(&rig, ALIAS, vec![]).await;
    assert_eq!(grant.provider, p1);

    rig.runtime.shutdown().await;
    drop(accept);
}

#[tokio::test]
async fn trust_epoch_fences_stale_verdicts() {
    let rig = start().await;
    let p1 = provider(30);
    let accept = connect(&rig, p1).await;
    heartbeat(&rig, p1, accept.epoch, 1, true).await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Never verified: structural reject (untrusted is not transient).
    let outcome = rig
        .fleet
        .admit(request(ALIAS, JobId::new(uuid::Uuid::new_v4()), vec![]))
        .await
        .expect("actor alive");
    match &outcome {
        AdmitOutcome::Reject(RejectionReason::AllGated { failures }) => {
            assert!(
                failures.contains_key(&GateFailure::Untrusted),
                "{failures:?}"
            );
        }
        other => panic!("expected untrusted reject, got {}", kind(other)),
    }

    // Hard downgrade at epoch 5; an older in-flight SelfSigned (epoch 4)
    // must NOT reverse it (plan §9.1.6).
    trust(
        &rig,
        p1,
        5,
        TrustVerdict::Untrusted {
            reason: "test downgrade".into(),
        },
    )
    .await;
    trust(&rig, p1, 4, TrustVerdict::SelfSigned).await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    let outcome = rig
        .fleet
        .admit(request(ALIAS, JobId::new(uuid::Uuid::new_v4()), vec![]))
        .await
        .expect("actor alive");
    assert!(
        matches!(outcome, AdmitOutcome::Reject(_)),
        "stale verdict reversed a downgrade: {}",
        kind(&outcome)
    );

    // A strictly newer verdict restores routability.
    trust(&rig, p1, 6, TrustVerdict::SelfSigned).await;
    let grant = admit_until_grant(&rig, ALIAS, vec![]).await;
    assert_eq!(grant.provider, p1);

    rig.runtime.shutdown().await;
    drop(accept);
}

#[tokio::test]
async fn calibration_corrects_predicted_first_content() {
    let rig = start().await;
    let p1 = provider(40);
    let accept = connect(&rig, p1).await;
    trust(&rig, p1, 1, TrustVerdict::SelfSigned).await;
    // Advisory prediction: 1000 ms.
    heartbeat_shaped(&rig, p1, accept.epoch, 1, true, 8, 1_000).await;

    let grant = admit_until_grant(&rig, ALIAS, vec![]).await;
    assert_eq!(grant.predicted_first_content, Duration::from_millis(1_000));

    // Predictions run 2x high: eight observations reach the calibration
    // window's min_samples and drive the median ratio to 0.5.
    for _ in 0..8 {
        rig.fleet
            .commands
            .send(FleetCommand::Observe(FleetObservation::FirstContent {
                provider: p1,
                model: ModelId::new(MODEL),
                predicted: Duration::from_millis(1_000),
                actual: Duration::from_millis(500),
            }))
            .await
            .expect("actor alive");
    }
    tokio::time::sleep(Duration::from_millis(100)).await;

    let grant = admit_until_grant(&rig, ALIAS, vec![]).await;
    assert_eq!(
        grant.predicted_first_content,
        Duration::from_millis(500),
        "calibration must halve the 2x-high prediction"
    );

    rig.runtime.shutdown().await;
    drop(accept);
}

#[tokio::test]
async fn snapshot_reports_providers_and_warm_models() {
    let rig = start().await;
    let p1 = provider(50);
    let accept = connect(&rig, p1).await;
    trust(&rig, p1, 1, TrustVerdict::SelfSigned).await;
    heartbeat(&rig, p1, accept.epoch, 1, true).await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    let (tx, rx) = oneshot::channel();
    rig.fleet
        .commands
        .send(FleetCommand::Snapshot { reply: tx })
        .await
        .expect("actor alive");
    let snapshot = rx.await.expect("snapshot");
    assert_eq!(snapshot.providers, 1);
    assert_eq!(snapshot.routable, 1);
    assert_eq!(snapshot.warm_by_model.get(MODEL), Some(&1));

    rig.runtime.shutdown().await;
    drop(accept);
}
