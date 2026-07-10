//! Property tests for the request reducer (plan section 21, Milestone 1
//! exit gate): arbitrary event interleavings can never produce two funded
//! starts, an alternate or hedge after funding, a mutated deadline, a second
//! terminal disposition, a leaked or double-released permit, or a leaked
//! lease. Rejected events leave the machine untouched by construction
//! (`apply` is `&self`).

mod common;

use std::collections::{HashMap, HashSet};

use common::{deadlines, job};
use darkbloom_core::ids::{AttemptId, LeaseId, ProviderId};
use darkbloom_core::money::Tokens;
use darkbloom_core::provider_error::ProviderErrorClass;
use darkbloom_core::request::{
    Effect, Event, HedgeOffer, Phase, PreparedFacts, RequestMachine, TerminalOutcome,
    TerminalSummary,
};
use darkbloom_core::settlement::ProviderClaimedUsage;
use darkbloom_core::time::{DurationMs, TimestampMs};
use proptest::prelude::*;
use uuid::Uuid;

#[derive(Debug, Clone, Copy)]
struct Op {
    code: u8,
    a: u8,
    b: u16,
}

fn op_strategy() -> impl Strategy<Value = Op> {
    (0u8..31, any::<u8>(), any::<u16>()).prop_map(|(code, a, b)| Op { code, a, b })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PermitStatus {
    /// Held by an admitted attempt or a pending hedge offer.
    Held,
    Released,
}

/// Full instrumented run: random ops, then a deterministic drain that must
/// bring the machine to `Finished` with zero leaked resources.
struct Harness {
    machine: RequestMachine,
    now: i64,
    reserve_committed: bool,
    next_id: u128,
    known_attempts: Vec<AttemptId>,
    permits: HashMap<AttemptId, PermitStatus>,
    /// Attempt -> leases delivered for it.
    attempt_leases: HashMap<AttemptId, Vec<LeaseId>>,
    live_leases: HashSet<LeaseId>,
    fund_effects: u32,
    money_disposals: u32,
    completes: u32,
    settles: u32,
    initial_deadlines: darkbloom_core::request::Deadlines,
}

impl Harness {
    fn new() -> Self {
        let d = deadlines();
        Self {
            machine: RequestMachine::new(job(), d),
            now: 0,
            reserve_committed: false,
            next_id: 1,
            known_attempts: Vec::new(),
            permits: HashMap::new(),
            attempt_leases: HashMap::new(),
            live_leases: HashSet::new(),
            fund_effects: 0,
            money_disposals: 0,
            completes: 0,
            settles: 0,
            initial_deadlines: d,
        }
    }

    fn fresh_attempt(&mut self) -> AttemptId {
        let id = AttemptId::new(Uuid::from_u128(0xAA00_0000 + self.next_id));
        self.next_id += 1;
        id
    }

    fn fresh_lease(&mut self) -> LeaseId {
        let id = LeaseId::new(Uuid::from_u128(0xBB00_0000 + self.next_id));
        self.next_id += 1;
        id
    }

    fn provider_for(&self, n: u8) -> ProviderId {
        ProviderId::new(Uuid::from_u128(0xCC00 + u128::from(n % 8)))
    }

    fn pick_attempt(&self, a: u8) -> AttemptId {
        if self.known_attempts.is_empty() {
            AttemptId::new(Uuid::from_u128(0xDEAD))
        } else {
            self.known_attempts[usize::from(a) % self.known_attempts.len()]
        }
    }

    fn dispose_attempt_leases(&mut self, attempt: AttemptId) {
        if let Some(leases) = self.attempt_leases.get(&attempt) {
            for l in leases {
                self.live_leases.remove(l);
            }
        }
    }

    /// Deliver one event; on success, run all invariant checks.
    fn deliver(&mut self, event: Event) {
        let funding_before = self.machine.funded_attempt().is_some();

        // Pre-register resources the caller hands over with the event.
        let (granted, offer): (Option<(AttemptId, ProviderId)>, Option<HedgeOffer>) = match &event {
            Event::AdmitGranted { attempt, provider } => (Some((*attempt, *provider)), None),
            Event::PreparedArrived { hedge_offer, .. } => (None, *hedge_offer),
            Event::HedgeTimerFired { offer } => (None, *offer),
            _ => (None, None),
        };
        let prepared_lease = match &event {
            Event::PreparedArrived { attempt, lease, .. } => Some((*attempt, *lease)),
            _ => None,
        };

        let Ok((next, effects)) = self
            .machine
            .apply(event.clone(), TimestampMs::new(self.now))
        else {
            // Rejected events leave the machine untouched (`apply` is
            // `&self`); the caller keeps its resources.
            return;
        };
        self.machine = next;

        if matches!(event, Event::ReserveCommitted) {
            self.reserve_committed = true;
        }
        if let Some((attempt, provider)) = granted {
            let _ = provider;
            self.known_attempts.push(attempt);
            let prior = self.permits.insert(attempt, PermitStatus::Held);
            assert!(prior.is_none(), "attempt id reused for a second permit");
        }
        let mut offer_pending = offer;
        if let Some(o) = offer_pending {
            let prior = self.permits.insert(o.attempt, PermitStatus::Held);
            assert!(prior.is_none(), "hedge offer id collides with a permit");
            self.known_attempts.push(o.attempt);
        }
        if let Some((attempt, lease)) = prepared_lease {
            self.live_leases.insert(lease);
            self.attempt_leases.entry(attempt).or_default().push(lease);
        }
        // Attempt-level closure evidence disposes that attempt's leases
        // (plan 9.2.9: terminal evidence, expiry, or session loss).
        match &event {
            Event::TerminalArrived { attempt, .. }
            | Event::AttemptTimedOut { attempt }
            | Event::SessionLost { attempt } => self.dispose_attempt_leases(*attempt),
            _ => {}
        }

        for effect in &effects {
            match effect {
                Effect::FundAndAuthorize { .. } => {
                    self.fund_effects += 1;
                    assert!(
                        !funding_before,
                        "funding effect emitted while funding was already chosen"
                    );
                }
                Effect::SendPrepare { attempt, .. } => {
                    assert!(
                        !funding_before,
                        "SendPrepare after funding was chosen (9.2.4)"
                    );
                    if let Some(o) = offer_pending {
                        if o.attempt == *attempt {
                            offer_pending = None; // consumed: permit stays held
                        }
                    }
                }
                Effect::RequestAdmission { .. } => {
                    assert!(
                        !funding_before,
                        "alternate admission after funding was chosen (9.2.4)"
                    );
                }
                Effect::SendStart { attempt, .. } => {
                    assert_eq!(
                        Some(*attempt),
                        self.machine.funded_attempt(),
                        "start sent for a non-funded attempt (9.2.3)"
                    );
                }
                Effect::ReleasePermit { attempt } => {
                    let status = self.permits.insert(*attempt, PermitStatus::Released);
                    assert_eq!(
                        status,
                        Some(PermitStatus::Held),
                        "permit released twice or never held (9.2.10)"
                    );
                }
                Effect::ReturnHedgeOffer { attempt, .. } => {
                    let status = self.permits.insert(*attempt, PermitStatus::Released);
                    assert_eq!(
                        status,
                        Some(PermitStatus::Held),
                        "hedge offer returned twice or never held"
                    );
                    if let Some(o) = offer_pending {
                        if o.attempt == *attempt {
                            offer_pending = None;
                        }
                    }
                }
                Effect::AbortLease { lease, .. } => {
                    self.live_leases.remove(lease);
                }
                Effect::SettleJob { attempt, .. } => {
                    self.settles += 1;
                    self.money_disposals += 1;
                    assert_eq!(
                        Some(*attempt),
                        self.machine.funded_attempt(),
                        "settlement for a non-funded attempt"
                    );
                    assert!(
                        self.machine.committed_attempt().is_some(),
                        "settlement without first-content commitment"
                    );
                }
                Effect::ReleaseJob => self.money_disposals += 1,
                Effect::EscalateReview { .. } => self.money_disposals += 1,
                Effect::CompleteRequest { .. } => self.completes += 1,
                Effect::DiscardQueuedFrame { .. } | Effect::RecordTerminalConflict { .. } => {}
                Effect::SendCancel { .. } => {}
            }
        }

        assert!(
            offer_pending.is_none(),
            "a delivered hedge offer was neither consumed nor returned"
        );

        // Global step invariants.
        assert_eq!(
            self.machine.deadlines(),
            self.initial_deadlines,
            "deadlines mutated (9.2.5)"
        );
        assert!(self.fund_effects <= 1, "two funded starts (9.2.3)");
        assert!(self.settles <= 1, "two settlements");
        assert!(
            self.money_disposals <= 1,
            "more than one money disposition for one job"
        );
        assert!(self.completes <= 1, "consumer answered twice");
        assert!(
            self.machine.attempts().len() <= darkbloom_core::request::MAX_ATTEMPTS,
            "attempt bound exceeded"
        );
        let live = self
            .machine
            .attempts()
            .iter()
            .filter(|a| !a.state.is_closed())
            .count();
        assert!(
            live <= 2,
            "more than two concurrently open attempts (9.2.3)"
        );
        if !self.reserve_committed {
            assert_eq!(
                self.money_disposals, 0,
                "money disposed without a reservation"
            );
        }
    }

    fn event_for(&mut self, op: Op) -> Option<Event> {
        let attempt = self.pick_attempt(op.a);
        Some(match op.code {
            0 => Event::ReserveCommitted,
            1 => Event::ReserveFailed,
            2 => {
                let id = self.fresh_attempt();
                Event::AdmitGranted {
                    attempt: id,
                    provider: self.provider_for(op.a),
                }
            }
            3 => Event::AdmitFailed {
                retry_after: Some(DurationMs::new(u64::from(op.b))),
            },
            4 => Event::PrepareWriteConfirmed { attempt },
            5 => Event::PrepareWriteFailed { attempt },
            6 => Event::PrepareWriteUnknown { attempt },
            7 => {
                let lease = self.fresh_lease();
                let offer = if op.a.is_multiple_of(3) {
                    let id = self.fresh_attempt();
                    Some(HedgeOffer {
                        attempt: id,
                        provider: self.provider_for(op.a.wrapping_add(1)),
                    })
                } else {
                    None
                };
                Event::PreparedArrived {
                    attempt,
                    lease,
                    facts: PreparedFacts {
                        first_content_eta: DurationMs::new(u64::from(op.b) % 12_000),
                        billable_input_tokens: Tokens::new(u32::from(op.a)),
                        max_output_tokens: Tokens::new(500),
                    },
                    hedge_offer: offer,
                }
            }
            8 => Event::PrepareRejected {
                attempt,
                class: match op.b % 5 {
                    0 => ProviderErrorClass::Capacity,
                    1 => ProviderErrorClass::InvalidRequest,
                    2 => ProviderErrorClass::Draining,
                    3 => ProviderErrorClass::Fault,
                    _ => ProviderErrorClass::Security,
                },
            },
            9 => {
                let offer = if op.a.is_multiple_of(2) {
                    let id = self.fresh_attempt();
                    Some(HedgeOffer {
                        attempt: id,
                        provider: self.provider_for(op.a.wrapping_add(3)),
                    })
                } else {
                    None
                };
                Event::HedgeTimerFired { offer }
            }
            10 => Event::FundAuthorized {
                attempt: self.machine.funded_attempt().unwrap_or(attempt),
            },
            11 => Event::FundFailed {
                attempt: self.machine.funded_attempt().unwrap_or(attempt),
            },
            12 => Event::StartWriteUnknown { attempt },
            13 => Event::StartRetryTimerFired,
            14 => Event::StartedAck { attempt },
            15 => Event::PreambleAccepted { attempt },
            16 => Event::ContentAccepted {
                attempt,
                cumulative_tokens: Tokens::new(u32::from(op.b)),
            },
            17 => Event::TerminalArrived {
                attempt,
                terminal: TerminalSummary {
                    digest: darkbloom_core::ids::TerminalDigest::new([op.a % 2; 32]),
                    outcome: match op.b % 3 {
                        0 => TerminalOutcome::Completed,
                        1 => TerminalOutcome::Cancelled,
                        _ => TerminalOutcome::Error(ProviderErrorClass::Fault),
                    },
                    usage: ProviderClaimedUsage {
                        prompt_tokens: Tokens::new(u32::from(op.a)),
                        completion_tokens: Tokens::new(u32::from(op.b) % 600),
                    },
                },
            },
            18 => Event::AbortAcked { attempt },
            19 => Event::CancelAcked { attempt },
            20 => Event::AttemptTimedOut { attempt },
            21 => Event::SessionLost { attempt },
            22 => Event::ConsumerCancelled,
            23 => Event::ConsumerPipeStalled,
            24 => Event::FirstContentDeadlineElapsed,
            25 => Event::TotalDeadlineElapsed,
            26 => Event::TerminalWaitElapsed,
            27 => Event::SettlementRecorded,
            28 => Event::ReleaseRecorded,
            29 => Event::ReviewRecorded,
            _ => {
                self.now += i64::from(op.b) % 2_000;
                return None;
            }
        })
    }

    /// Deterministically finish the request: after this the machine must be
    /// `Finished` with every permit released and every lease disposed.
    fn drain(&mut self) {
        for _ in 0..12 {
            if self.machine.is_finished() {
                break;
            }
            match self.machine.phase() {
                Phase::Reserving => self.deliver(Event::ReserveFailed),
                Phase::Admitting => self.deliver(Event::AdmitFailed { retry_after: None }),
                Phase::Finalizing => self.deliver(Event::ReleaseRecorded),
                Phase::AwaitingTerminal { .. } => self.deliver(Event::TerminalWaitElapsed),
                _ => {
                    let open: Vec<AttemptId> = self
                        .machine
                        .attempts()
                        .iter()
                        .filter(|a| !a.state.is_closed())
                        .map(|a| a.id)
                        .collect();
                    for id in open {
                        self.deliver(Event::AttemptTimedOut { attempt: id });
                    }
                }
            }
            self.now += 100;
        }
        // Close any attempt records that survived the request resolution
        // (benign post-finish evidence must still dispose their leases).
        let open: Vec<AttemptId> = self
            .machine
            .attempts()
            .iter()
            .filter(|a| !a.state.is_closed())
            .map(|a| a.id)
            .collect();
        for id in open {
            self.deliver(Event::AttemptTimedOut { attempt: id });
        }

        assert!(
            self.machine.is_finished(),
            "drain could not finish the machine; stuck in {:?}",
            self.machine.phase().name()
        );
        for (attempt, status) in &self.permits {
            assert_eq!(
                *status,
                PermitStatus::Released,
                "permit for attempt {attempt} leaked (9.2.10)"
            );
        }
        assert!(
            self.live_leases.is_empty(),
            "leases leaked without disposal (9.2.9): {:?}",
            self.live_leases
        );
        for rec in self.machine.attempts() {
            assert!(rec.state.is_closed(), "attempt record left open");
            assert!(rec.permit_released, "attempt permit flag not released");
        }
        if self.reserve_committed {
            assert_eq!(
                self.money_disposals, 1,
                "a reserved job must get exactly one money disposition"
            );
        } else {
            assert_eq!(self.money_disposals, 0);
        }
        assert!(self.completes <= 1);
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    /// The headline reducer property (plan 21 Milestone 1 exit gate).
    #[test]
    fn arbitrary_event_traces_uphold_all_invariants(
        ops in proptest::collection::vec(op_strategy(), 1..100)
    ) {
        let mut h = Harness::new();
        for op in ops {
            // Time creeps forward on every step; deadline events are
            // delivered at whatever `now` happens to be, exercising both
            // the rejection and the elapsed paths.
            h.now += 25;
            if let Some(event) = h.event_for(op) {
                h.deliver(event);
            }
        }
        h.drain();
    }

    /// A trace biased toward the happy path plus adversarial terminals
    /// still yields at most one settlement and one disposition.
    #[test]
    fn happy_path_with_adversarial_tail(
        tail in proptest::collection::vec(op_strategy(), 0..40)
    ) {
        let mut h = Harness::new();
        h.deliver(Event::ReserveCommitted);
        let a = h.fresh_attempt();
        h.deliver(Event::AdmitGranted { attempt: a, provider: h.provider_for(1) });
        h.deliver(Event::PrepareWriteConfirmed { attempt: a });
        let lease = h.fresh_lease();
        h.attempt_leases.entry(a).or_default().push(lease);
        h.live_leases.insert(lease);
        let (next, _) = h.machine.apply(Event::PreparedArrived {
            attempt: a,
            lease,
            facts: PreparedFacts {
                first_content_eta: DurationMs::new(200),
                billable_input_tokens: Tokens::new(50),
                max_output_tokens: Tokens::new(100),
            },
            hedge_offer: None,
        }, TimestampMs::new(h.now)).expect("prepared");
        h.machine = next;
        h.fund_effects = 1;
        // Manually mark the permit ledger consistent with the shortcut.
        h.permits.insert(a, PermitStatus::Released);
        h.reserve_committed = true;
        h.deliver(Event::FundAuthorized { attempt: a });
        h.deliver(Event::StartedAck { attempt: a });
        h.deliver(Event::ContentAccepted { attempt: a, cumulative_tokens: Tokens::new(10) });
        for op in tail {
            h.now += 25;
            if let Some(event) = h.event_for(op) {
                h.deliver(event);
            }
        }
        h.drain();
    }
}
