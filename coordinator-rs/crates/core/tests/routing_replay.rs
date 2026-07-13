//! Full replay of the committed Go routing-simulation decisions.

use darkbloom_coordinator_core::{
    fleet::{
        AdmissionDemand, AdmissionError, AdmissionKind, Candidate, CapacitySnapshot, HealthState,
        PrefillDecodeRatioMilli, ProviderSnapshot, ScoringPolicy, TtftGateMode, TtftOutcome, admit,
        estimate_idle_ttft_microseconds, evaluate_ttft_gate, rank, score,
    },
    ids::{
        HardwareClass, ModelId, ModelRevision, ProviderId, SessionId, SessionRevision,
        TrustRevision,
    },
    money::MicroUsd,
    request::ProviderFence,
    tokens::{KvBytes, MilliTokensPerSecond, TokenCount},
    traits::{ProviderTraits, RequestTraits},
};
use serde::Deserialize;
use uuid::Uuid;

const CONTRACT_JSON: &str =
    include_str!("../../../../tests/contracts/routing/ttft_calibration.json");

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RoutingContract {
    schema_version: u32,
    model: String,
    prompt_data: String,
    prompt_tokens: Vec<u64>,
    max_completion_tokens: u64,
    deadline: DeadlineFixture,
    capacity: CapacityFixture,
    providers: Vec<ProviderFixture>,
    scenarios: Vec<ScenarioFixture>,
    scoring_cases: Vec<ScoringCaseFixture>,
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct DeadlineFixture {
    base_microseconds: u64,
    per_prompt_token_microseconds: u64,
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct CapacityFixture {
    token_capacity: u64,
    kv_capacity_bytes: u64,
    concurrency_limit: u32,
    kv_bytes_per_token: u64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderFixture {
    id: String,
    decode_milli_tps: u64,
    effective_decode_milli_tps: u64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ScenarioFixture {
    name: String,
    prefill_to_decode_ratio_milli: u64,
    soft_ttft_gate: bool,
    best_ttft_microseconds: Vec<u64>,
    has_ttft_runs: Vec<RunFixture<bool>>,
    expected_outcome_runs: Vec<RunFixture<ExpectedOutcome>>,
    candidate_count_runs: Vec<RunFixture<u32>>,
    capacity_rejection_runs: Vec<RunFixture<u32>>,
    expected_stable_rank_first_provider_id_runs: Vec<RunFixture<String>>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RunFixture<T> {
    count: usize,
    value: T,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ScoringCaseFixture {
    name: String,
    prompt_tokens: u64,
    prefill_to_decode_ratio_milli: u64,
    microseconds_per_micro_usd: u64,
    queue_penalty_microseconds: u64,
    candidates: Vec<ScoringCandidateFixture>,
    actual_selected_provider_index: usize,
    actual_selected_provider_id: String,
    go_decision: GoScoringDecisionFixture,
    expected_rust_this_request_delta_microseconds: i64,
    expected_rust_total_delta_microseconds: i64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ScoringCandidateFixture {
    go_provider_id: String,
    core_provider_id: String,
    predicted_ttft_microseconds: u64,
    request_prefill_microseconds: u64,
    completion_tokens: u64,
    decode_milli_tps: u64,
    quoted_micro_usd: u64,
    queue_depth: u32,
    state_penalty_microseconds: u64,
    pending_penalty_microseconds: u64,
    backlog_penalty_microseconds: u64,
    health_penalty_microseconds: u64,
    capacity_rate_penalty_microseconds: u64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct GoScoringDecisionFixture {
    total_microseconds: u64,
    state_microseconds: u64,
    queue_microseconds: u64,
    pending_microseconds: u64,
    backlog_microseconds: u64,
    this_request_microseconds: u64,
    health_microseconds: u64,
    capacity_rate_microseconds: u64,
    effective_decode_milli_tps: u64,
    effective_queue: u32,
    candidate_count: usize,
    ttft_microseconds: u64,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
enum ExpectedOutcome {
    Served,
    MachineBusy,
    TtftTooSlow,
}

impl From<TtftOutcome> for ExpectedOutcome {
    fn from(value: TtftOutcome) -> Self {
        match value {
            TtftOutcome::Served => Self::Served,
            TtftOutcome::MachineBusy => Self::MachineBusy,
            TtftOutcome::TtftTooSlow => Self::TtftTooSlow,
        }
    }
}

fn expand_runs<T: Clone>(
    runs: &[RunFixture<T>],
    expected_len: usize,
    scenario: &str,
    field: &str,
) -> Vec<T> {
    let mut expanded = Vec::with_capacity(expected_len);
    for run in runs {
        assert!(run.count > 0, "{scenario} {field} contains an empty run");
        let next_len = expanded
            .len()
            .checked_add(run.count)
            .expect("fixture run length overflow");
        assert!(
            next_len <= expected_len,
            "{scenario} {field} expands past {expected_len} decisions"
        );
        expanded.extend(std::iter::repeat_n(run.value.clone(), run.count));
    }
    assert_eq!(
        expanded.len(),
        expected_len,
        "{scenario} {field} expanded decision count"
    );
    expanded
}

fn scoring_prefill_microseconds(
    prompt_tokens: TokenCount,
    ratio: PrefillDecodeRatioMilli,
    decode_rate: MilliTokensPerSecond,
) -> u64 {
    let numerator = u128::from(prompt_tokens.get())
        .checked_mul(1_000_000_000_000)
        .expect("bounded fixture prefill numerator");
    let denominator = u128::from(ratio.get())
        .checked_mul(u128::from(decode_rate.get()))
        .expect("bounded fixture prefill denominator");
    let value = numerator
        .checked_add(denominator - 1)
        .expect("bounded fixture prefill rounding")
        / denominator;
    u64::try_from(value).expect("fixture prefill fits u64")
}

struct ReplayProvider {
    id: ProviderId,
    static_decode: MilliTokensPerSecond,
    effective_decode: MilliTokensPerSecond,
    snapshot: ProviderSnapshot,
}

struct ScenarioReport {
    name: String,
    candidate_counts: Vec<u32>,
    winners: Vec<Option<ProviderId>>,
    outcomes: Vec<ExpectedOutcome>,
    prediction_error_total_microseconds: u64,
    prediction_error_max_microseconds: u64,
}

fn build_providers(contract: &RoutingContract) -> Vec<ReplayProvider> {
    let model_id = ModelId::new(contract.model.clone()).expect("valid fixture model");
    contract
        .providers
        .iter()
        .map(|provider| {
            let uuid = Uuid::parse_str(&provider.id).expect("valid fixture provider UUID");
            let id = ProviderId::new(uuid).expect("non-nil fixture provider");
            let snapshot = ProviderSnapshot::new(
                ProviderFence {
                    provider_id: id,
                    session_id: SessionId::new(uuid).expect("non-nil fixture session"),
                    session_revision: SessionRevision::new(1).expect("nonzero revision"),
                    trust_revision: TrustRevision::new(1).expect("nonzero revision"),
                    model_id: model_id.clone(),
                    model_revision: ModelRevision::new(1).expect("nonzero revision"),
                },
                HardwareClass::new("routing-contract").expect("valid hardware class"),
                ProviderTraits::new(TokenCount::new(contract.capacity.token_capacity), [], true),
                CapacitySnapshot::new(
                    TokenCount::new(contract.capacity.token_capacity),
                    TokenCount::ZERO,
                    KvBytes::new(contract.capacity.kv_capacity_bytes),
                    KvBytes::ZERO,
                    contract.capacity.concurrency_limit,
                    0,
                )
                .expect("valid fixture capacity"),
                HealthState::new(),
            );
            ReplayProvider {
                id,
                static_decode: MilliTokensPerSecond::new(provider.decode_milli_tps)
                    .expect("positive static decode rate"),
                effective_decode: MilliTokensPerSecond::new(provider.effective_decode_milli_tps)
                    .expect("positive effective decode rate"),
                snapshot,
            }
        })
        .collect()
}

fn replay_scenario(
    contract: &RoutingContract,
    providers: &[ReplayProvider],
    scenario: &ScenarioFixture,
) -> ScenarioReport {
    let ratio = PrefillDecodeRatioMilli::new(scenario.prefill_to_decode_ratio_milli)
        .expect("positive fixture ratio");
    let mode = if scenario.soft_ttft_gate {
        TtftGateMode::Soft
    } else {
        TtftGateMode::Hard
    };
    let decision_count = contract.prompt_tokens.len();
    assert_eq!(
        scenario.best_ttft_microseconds.len(),
        decision_count,
        "{} best TTFT decision count",
        scenario.name
    );
    let has_ttft = expand_runs(
        &scenario.has_ttft_runs,
        decision_count,
        &scenario.name,
        "has_ttft",
    );
    let expected_outcomes = expand_runs(
        &scenario.expected_outcome_runs,
        decision_count,
        &scenario.name,
        "expected_outcome",
    );
    let expected_candidate_counts = expand_runs(
        &scenario.candidate_count_runs,
        decision_count,
        &scenario.name,
        "candidate_count",
    );
    let expected_capacity_rejections = expand_runs(
        &scenario.capacity_rejection_runs,
        decision_count,
        &scenario.name,
        "capacity_rejection",
    );
    let expected_winners = expand_runs(
        &scenario.expected_stable_rank_first_provider_id_runs,
        decision_count,
        &scenario.name,
        "stable_rank_first_provider_id",
    );
    let mut report = ScenarioReport {
        name: scenario.name.clone(),
        candidate_counts: Vec::with_capacity(decision_count),
        winners: Vec::with_capacity(decision_count),
        outcomes: Vec::with_capacity(decision_count),
        prediction_error_total_microseconds: 0,
        prediction_error_max_microseconds: 0,
    };

    for (position, prompt_tokens) in contract.prompt_tokens.iter().copied().enumerate() {
        let prompt = TokenCount::new(prompt_tokens);
        let completion = TokenCount::new(contract.max_completion_tokens);
        let total = prompt.checked_add(completion).expect("fixture token sum");
        let kv_bytes = total
            .get()
            .checked_mul(contract.capacity.kv_bytes_per_token)
            .expect("fixture KV calculation");
        let demand = AdmissionDemand::new(prompt, completion, KvBytes::new(kv_bytes))
            .expect("valid fixture demand");
        let traits = RequestTraits::new(total);
        let mut candidates = Vec::with_capacity(providers.len());
        let mut capacity_rejections = 0_u32;
        let mut best_ttft_microseconds = None;

        for provider in providers {
            match admit(&provider.snapshot, &traits, demand, AdmissionKind::Regular) {
                Ok(_) => {
                    let predicted = estimate_idle_ttft_microseconds(
                        prompt,
                        ratio,
                        provider.static_decode,
                        provider.effective_decode,
                    )
                    .expect("bounded fixture TTFT");
                    best_ttft_microseconds = Some(
                        best_ttft_microseconds.map_or(predicted, |best: u64| best.min(predicted)),
                    );
                    candidates.push(Candidate {
                        provider_id: provider.id,
                        request_prefill_microseconds: scoring_prefill_microseconds(
                            prompt,
                            ratio,
                            provider.static_decode,
                        ),
                        completion_tokens: completion,
                        decode_rate: provider.effective_decode,
                        quoted_price: MicroUsd::ZERO,
                        queue_depth: 0,
                        state_penalty_microseconds: 0,
                        pending_penalty_microseconds: 0,
                        backlog_penalty_microseconds: 0,
                        health_penalty_microseconds: 0,
                        capacity_rate_penalty_microseconds: 0,
                    });
                }
                Err(
                    AdmissionError::TokenBudgetExceeded { .. }
                    | AdmissionError::KvBudgetExceeded { .. }
                    | AdmissionError::ConcurrencyExceeded { .. },
                ) => {
                    capacity_rejections = capacity_rejections
                        .checked_add(1)
                        .expect("provider count fits u32");
                }
                Err(error) => panic!(
                    "{} arrival {} unexpected admission error: {error}",
                    scenario.name, position
                ),
            }
        }

        let candidate_count = u32::try_from(candidates.len()).expect("provider count fits u32");
        assert_eq!(
            candidate_count, expected_candidate_counts[position],
            "{} arrival {} candidate count",
            scenario.name, position
        );
        assert_eq!(
            capacity_rejections, expected_capacity_rejections[position],
            "{} arrival {} capacity rejects",
            scenario.name, position
        );

        let predicted_best = best_ttft_microseconds;
        assert_eq!(
            predicted_best.is_some(),
            has_ttft[position],
            "{} arrival {} TTFT presence",
            scenario.name,
            position
        );
        if let Some(predicted) = predicted_best {
            let expected_best = scenario.best_ttft_microseconds[position];
            let error = predicted.abs_diff(expected_best);
            assert!(
                error <= 1,
                "{} arrival {} best TTFT prediction {}us differs from Go {}us",
                scenario.name,
                position,
                predicted,
                expected_best
            );
            report.prediction_error_total_microseconds = report
                .prediction_error_total_microseconds
                .checked_add(error)
                .expect("bounded replay error");
            report.prediction_error_max_microseconds =
                report.prediction_error_max_microseconds.max(error);
        }

        let deadline_microseconds = contract
            .deadline
            .per_prompt_token_microseconds
            .checked_mul(prompt_tokens)
            .and_then(|prompt| contract.deadline.base_microseconds.checked_add(prompt))
            .expect("fixture deadline calculation");
        let outcome = evaluate_ttft_gate(
            candidate_count,
            capacity_rejections,
            predicted_best,
            deadline_microseconds,
            mode,
        );
        assert_eq!(
            ExpectedOutcome::from(outcome),
            expected_outcomes[position],
            "{} arrival {} outcome",
            scenario.name,
            position
        );

        let ranked = rank(
            candidates,
            ScoringPolicy {
                microseconds_per_micro_usd: 0,
                queue_penalty_microseconds: 0,
            },
        )
        .expect("fixture candidates score");
        let winner = ranked.first().map(|candidate| candidate.provider_id);
        let expected_winner = ProviderId::new(
            Uuid::parse_str(&expected_winners[position]).expect("valid expected winner UUID"),
        )
        .expect("non-nil expected winner");
        assert_eq!(
            winner,
            Some(expected_winner),
            "{} arrival {} stable rank winner",
            scenario.name,
            position
        );

        report.candidate_counts.push(candidate_count);
        report.winners.push(winner);
        report.outcomes.push(expected_outcomes[position]);
    }
    report
}

fn replay_scoring_cases(contract: &RoutingContract) {
    assert!(
        contract.scoring_cases.len() >= 2,
        "fixture must exercise multiple real Go scheduler selections"
    );
    for case in &contract.scoring_cases {
        assert_eq!(
            case.go_decision.candidate_count,
            case.candidates.len(),
            "{} Go decision candidate count",
            case.name
        );
        assert!(case.go_decision.total_microseconds > 0);
        let ratio = PrefillDecodeRatioMilli::new(case.prefill_to_decode_ratio_milli)
            .expect("positive scoring ratio");
        let prompt = TokenCount::new(case.prompt_tokens);
        let policy = ScoringPolicy {
            microseconds_per_micro_usd: case.microseconds_per_micro_usd,
            queue_penalty_microseconds: case.queue_penalty_microseconds,
        };
        let mut candidates = Vec::with_capacity(case.candidates.len());
        for candidate in &case.candidates {
            let decode = MilliTokensPerSecond::new(candidate.decode_milli_tps)
                .expect("positive scoring decode rate");
            let calculated_ttft = estimate_idle_ttft_microseconds(prompt, ratio, decode, decode)
                .expect("bounded scoring TTFT");
            assert!(
                calculated_ttft.abs_diff(candidate.predicted_ttft_microseconds) <= 1,
                "{} candidate {} TTFT input drift",
                case.name,
                candidate.go_provider_id
            );
            assert_eq!(
                scoring_prefill_microseconds(prompt, ratio, decode),
                candidate.request_prefill_microseconds,
                "{} candidate {} prefill scoring input",
                case.name,
                candidate.go_provider_id
            );
            candidates.push(Candidate {
                provider_id: ProviderId::new(
                    Uuid::parse_str(&candidate.core_provider_id)
                        .expect("valid scoring provider UUID"),
                )
                .expect("non-nil scoring provider"),
                request_prefill_microseconds: candidate.request_prefill_microseconds,
                completion_tokens: TokenCount::new(candidate.completion_tokens),
                decode_rate: decode,
                quoted_price: MicroUsd::new(candidate.quoted_micro_usd),
                queue_depth: candidate.queue_depth,
                state_penalty_microseconds: candidate.state_penalty_microseconds,
                pending_penalty_microseconds: candidate.pending_penalty_microseconds,
                backlog_penalty_microseconds: candidate.backlog_penalty_microseconds,
                health_penalty_microseconds: candidate.health_penalty_microseconds,
                capacity_rate_penalty_microseconds: candidate.capacity_rate_penalty_microseconds,
            });
        }

        let individual_scores: Vec<_> = candidates
            .iter()
            .copied()
            .map(|candidate| score(candidate, policy).expect("scoring case score"))
            .collect();
        assert_eq!(individual_scores.len(), case.candidates.len());
        let ranked = rank(candidates, policy).expect("scoring case rank");
        let winner = ranked.first().expect("nonempty scoring case").provider_id;
        let selected_fixture = case
            .candidates
            .get(case.actual_selected_provider_index)
            .expect("actual Go selected index in range");
        let selected_score = individual_scores
            .get(case.actual_selected_provider_index)
            .expect("actual Go selected score in range");
        assert_eq!(
            selected_fixture.go_provider_id, case.actual_selected_provider_id,
            "{} actual Go selected ID/index consistency",
            case.name
        );
        let expected_core_id = ProviderId::new(
            Uuid::parse_str(&selected_fixture.core_provider_id)
                .expect("valid selected core provider UUID"),
        )
        .expect("non-nil selected core provider");
        assert_eq!(
            winner, expected_core_id,
            "{} Rust rank disagrees with actual Go scheduler selection {}",
            case.name, case.actual_selected_provider_id
        );
        assert_eq!(
            selected_fixture.decode_milli_tps, case.go_decision.effective_decode_milli_tps,
            "{} selected effective TPS",
            case.name
        );
        assert_eq!(
            selected_fixture.queue_depth, case.go_decision.effective_queue,
            "{} selected effective queue",
            case.name
        );
        assert_eq!(
            selected_score.state_microseconds, case.go_decision.state_microseconds,
            "{} state component",
            case.name
        );
        assert_eq!(
            selected_score.queue_microseconds, case.go_decision.queue_microseconds,
            "{} queue component",
            case.name
        );
        assert_eq!(
            selected_score.pending_microseconds, case.go_decision.pending_microseconds,
            "{} pending component",
            case.name
        );
        assert_eq!(
            selected_score.backlog_microseconds, case.go_decision.backlog_microseconds,
            "{} backlog component",
            case.name
        );
        assert_eq!(
            selected_score.health_microseconds, case.go_decision.health_microseconds,
            "{} health component",
            case.name
        );
        assert_eq!(
            selected_score.capacity_rate_microseconds, case.go_decision.capacity_rate_microseconds,
            "{} capacity-rate component",
            case.name
        );
        assert_eq!(
            selected_score.price_microseconds, 0,
            "{} zero-price component",
            case.name
        );
        let this_request_delta = i64::try_from(selected_score.this_request_microseconds)
            .expect("bounded Rust this-request component")
            - i64::try_from(case.go_decision.this_request_microseconds)
                .expect("bounded Go this-request component");
        assert_eq!(
            this_request_delta, case.expected_rust_this_request_delta_microseconds,
            "{} exact this-request rounding delta",
            case.name
        );
        assert!(
            this_request_delta.abs() <= 1,
            "{} material this-request scoring drift: {this_request_delta}us",
            case.name
        );
        let total_delta = i64::try_from(selected_score.total.get())
            .expect("bounded Rust score total")
            - i64::try_from(case.go_decision.total_microseconds).expect("bounded Go score total");
        assert_eq!(
            total_delta, case.expected_rust_total_delta_microseconds,
            "{} exact total rounding delta",
            case.name
        );
        assert!(
            total_delta.abs() <= 1,
            "{} material total scoring drift: {total_delta}us",
            case.name
        );
        let go_component_total = case
            .go_decision
            .state_microseconds
            .checked_add(case.go_decision.queue_microseconds)
            .and_then(|total| total.checked_add(case.go_decision.pending_microseconds))
            .and_then(|total| total.checked_add(case.go_decision.backlog_microseconds))
            .and_then(|total| total.checked_add(case.go_decision.this_request_microseconds))
            .and_then(|total| total.checked_add(case.go_decision.health_microseconds))
            .and_then(|total| total.checked_add(case.go_decision.capacity_rate_microseconds))
            .expect("bounded Go decision component sum");
        assert!(
            go_component_total.abs_diff(case.go_decision.total_microseconds) <= 2,
            "{} Go decision components do not reconcile",
            case.name
        );
        assert!(
            selected_fixture
                .predicted_ttft_microseconds
                .abs_diff(case.go_decision.ttft_microseconds)
                <= 2,
            "{} selected TTFT differs from real Go RoutingDecision",
            case.name
        );
        eprintln!(
            "routing scoring replay {}: candidates={}, selected_index={}, selected_id={}, \
             go_cost_us={}, go_ttft_us={}",
            case.name,
            case.candidates.len(),
            case.actual_selected_provider_index,
            case.actual_selected_provider_id,
            case.go_decision.total_microseconds,
            case.go_decision.ttft_microseconds,
        );
    }
}

#[test]
fn committed_routing_contract_replays_every_decision_through_core() {
    let contract: RoutingContract =
        serde_json::from_str(CONTRACT_JSON).expect("schema-v2 routing fixture");
    assert_eq!(contract.schema_version, 2);
    assert_eq!(
        contract.prompt_data,
        "synthetic token counts only; no prompt or response content"
    );
    assert!(!CONTRACT_JSON.contains("\"messages\""));
    assert!(!CONTRACT_JSON.contains("\"prompt_content\""));
    assert!(!CONTRACT_JSON.contains("\"response_content\""));
    assert_eq!(contract.providers.len(), 70);
    assert_eq!(contract.scenarios.len(), 3);
    assert_eq!(contract.prompt_tokens.len(), 1_500);
    assert_eq!(contract.max_completion_tokens, 512);
    assert_eq!(contract.deadline.base_microseconds, 5_000_000);
    assert_eq!(contract.deadline.per_prompt_token_microseconds, 1_000);
    replay_scoring_cases(&contract);

    let providers = build_providers(&contract);
    let reports: Vec<_> = contract
        .scenarios
        .iter()
        .map(|scenario| replay_scenario(&contract, &providers, scenario))
        .collect();
    let baseline = &reports[0];
    assert!(!baseline.outcomes.is_empty());

    for report in &reports {
        let decisions = report.outcomes.len();
        let mean_error = if decisions == 0 {
            0.0
        } else {
            report.prediction_error_total_microseconds as f64 / decisions as f64
        };
        let candidate_changes = baseline
            .candidate_counts
            .iter()
            .zip(&report.candidate_counts)
            .filter(|(before, after)| before != after)
            .count();
        let rank_changes = baseline
            .winners
            .iter()
            .zip(&report.winners)
            .filter(|(before, after)| before != after)
            .count();
        let outcome_changes = baseline
            .outcomes
            .iter()
            .zip(&report.outcomes)
            .filter(|(before, after)| before != after)
            .count();
        eprintln!(
            "routing replay {}: decisions={}, candidate_changes={}, rank_changes={}, \
             outcome_changes={}, prediction_error_mean_us={:.3}, prediction_error_max_us={}",
            report.name,
            decisions,
            candidate_changes,
            rank_changes,
            outcome_changes,
            mean_error,
            report.prediction_error_max_microseconds,
        );
    }

    let changed_from_legacy = reports[1]
        .outcomes
        .iter()
        .zip(&baseline.outcomes)
        .filter(|(calibrated, legacy)| calibrated != legacy)
        .count();
    let changed_by_soft_gate = reports[2]
        .outcomes
        .iter()
        .zip(&reports[1].outcomes)
        .filter(|(soft, hard)| soft != hard)
        .count();
    assert!(changed_from_legacy > 0);
    assert!(changed_by_soft_gate > 0);
}
