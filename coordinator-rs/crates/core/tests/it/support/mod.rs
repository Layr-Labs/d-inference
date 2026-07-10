//! Shared fixtures and a deterministic driver for request-machine tests.

#![allow(dead_code)]

use darkbloom_core::ids::{AttemptId, JobId, LeaseId, ProviderId, TerminalDigest};
use darkbloom_core::money::Tokens;
use darkbloom_core::request::{
    Deadlines, Effect, Event, PreparedFacts, RequestMachine, TerminalOutcome, TerminalSummary,
    TransitionError,
};
use darkbloom_core::settlement::ProviderClaimedUsage;
use darkbloom_core::time::{DurationMs, TimestampMs};
use uuid::Uuid;

pub fn job() -> JobId {
    JobId::new(Uuid::from_u128(0xA0))
}

pub fn attempt(n: u128) -> AttemptId {
    AttemptId::new(Uuid::from_u128(0xB000 + n))
}

pub fn provider(n: u128) -> ProviderId {
    ProviderId::new(Uuid::from_u128(0xC000 + n))
}

pub fn lease(n: u128) -> LeaseId {
    LeaseId::new(Uuid::from_u128(0xD000 + n))
}

pub fn digest(n: u8) -> TerminalDigest {
    TerminalDigest::new([n; 32])
}

pub const FIRST_CONTENT_DEADLINE: i64 = 10_000;
pub const TOTAL_DEADLINE: i64 = 60_000;

pub fn deadlines() -> Deadlines {
    Deadlines {
        first_content: TimestampMs::new(FIRST_CONTENT_DEADLINE),
        total: TimestampMs::new(TOTAL_DEADLINE),
    }
}

pub fn facts(eta_ms: u64) -> PreparedFacts {
    PreparedFacts {
        first_content_eta: DurationMs::new(eta_ms),
        billable_input_tokens: Tokens::new(100),
        max_output_tokens: Tokens::new(500),
    }
}

pub fn terminal(digest_byte: u8, outcome: TerminalOutcome, completion: u32) -> TerminalSummary {
    TerminalSummary {
        digest: digest(digest_byte),
        outcome,
        usage: ProviderClaimedUsage {
            prompt_tokens: Tokens::new(100),
            completion_tokens: Tokens::new(completion),
        },
    }
}

/// Deterministic test driver: owns the machine and a logical clock.
pub struct Driver {
    pub machine: RequestMachine,
    pub now: TimestampMs,
}

impl Driver {
    pub fn new() -> Self {
        Self {
            machine: RequestMachine::new(job(), deadlines()),
            now: TimestampMs::new(0),
        }
    }

    pub fn advance(&mut self, ms: i64) {
        self.now = TimestampMs::new(self.now.get() + ms);
    }

    /// Apply an event that must succeed; returns the effects.
    pub fn ok(&mut self, event: Event) -> Vec<Effect> {
        let (next, effects) = self
            .machine
            .apply(event.clone(), self.now)
            .unwrap_or_else(|e| panic!("event {} rejected: {e}", event.name()));
        self.machine = next;
        effects
    }

    /// Apply an event that must be rejected; returns the error. The machine
    /// is unchanged.
    pub fn err(&mut self, event: Event) -> TransitionError {
        match self.machine.apply(event.clone(), self.now) {
            Ok(_) => panic!("event {} unexpectedly accepted", event.name()),
            Err(e) => e,
        }
    }

    // ---- staged setup helpers ------------------------------------------

    /// Reserve committed, admission granted for attempt 1 / provider 1,
    /// prepare on the wire (confirmed).
    pub fn drive_to_preparing(&mut self) {
        self.ok(Event::ReserveCommitted);
        self.ok(Event::AdmitGranted {
            attempt: attempt(1),
            provider: provider(1),
        });
        self.ok(Event::PrepareWriteConfirmed {
            attempt: attempt(1),
        });
    }

    /// Through prepared with a usable lease: the funding CAS fires.
    pub fn drive_to_funding(&mut self) {
        self.drive_to_preparing();
        self.ok(Event::PreparedArrived {
            attempt: attempt(1),
            lease: lease(1),
            facts: facts(500),
            hedge_offer: None,
        });
    }

    /// Through fund authorization: start is on the wire.
    pub fn drive_to_starting(&mut self) {
        self.drive_to_funding();
        self.ok(Event::FundAuthorized {
            attempt: attempt(1),
        });
    }

    /// Started acknowledged, no content yet.
    pub fn drive_to_awaiting_content(&mut self) {
        self.drive_to_starting();
        self.ok(Event::StartedAck {
            attempt: attempt(1),
        });
    }

    /// First content accepted: the request is committed.
    pub fn drive_to_streaming(&mut self) {
        self.drive_to_awaiting_content();
        self.ok(Event::ContentAccepted {
            attempt: attempt(1),
            cumulative_tokens: Tokens::new(10),
        });
    }
}

/// Collect all effects matching a predicate.
pub fn filter_effects<'a>(
    effects: &'a [Effect],
    pred: impl Fn(&Effect) -> bool + 'a,
) -> Vec<&'a Effect> {
    effects.iter().filter(|e| pred(e)).collect()
}

pub fn has_effect(effects: &[Effect], pred: impl Fn(&Effect) -> bool) -> bool {
    effects.iter().any(pred)
}
