package attempt

// Typed provider terminal causes (InferenceErrorMessage.TerminalCause).
//
// Background (docs/reports/2026-07-20-generation-deadline-incident-and-redesign.md):
// the provider engine's flat 120s wall killed healthy requests and reported
// them as generic 500 inference_errors, so the coordinator recorded a provider
// job failure and struck every health breaker ~178K times/week for what was
// the PLATFORM's own policy. New providers now attach a typed terminal_cause
// so the coordinator can tell platform-policy terminals from real provider
// sickness. The vocabulary is CLOSED and mirrored bit-for-bit by the Swift
// provider — do not rename values.
//
// Classification policy (the cause → breaker table from the incident report):
//
//	admission_timeout     → neutral for node/shape/identity health; recorded
//	                        as a capacity signal (black-hole cooldown strike
//	                        only — RecordCapacityRejectBusy)
//	safety_deadline       → fully neutral (platform policy, not a fault)
//	backpressure_timeout  → fully neutral (client/coordinator slowness)
//	cancelled             → fully neutral (consumer behavior)
//	prefill_stall         → fault (real provider sickness): legacy funnels
//	decode_stall          → fault: legacy funnels
//	watchdog              → fault: legacy funnels
//	engine_error          → legacy behavior exactly
//	absent ("")           → legacy provider: legacy behavior exactly
//	unknown value         → treated as absent, plus a vocabulary-drift metric
//
// "Neutral" means NEUTRAL, not positive: neutral terminals never strike a
// breaker AND never clear one or count as an accept/success.
const (
	TerminalCauseAdmissionTimeout    = "admission_timeout"
	TerminalCausePrefillStall        = "prefill_stall"
	TerminalCauseDecodeStall         = "decode_stall"
	TerminalCauseSafetyDeadline      = "safety_deadline"
	TerminalCauseBackpressureTimeout = "backpressure_timeout"
	TerminalCauseWatchdog            = "watchdog"
	TerminalCauseCancelled           = "cancelled"
	TerminalCauseEngineError         = "engine_error"
)

// TerminalCauseClass is the coordinator-side health classification of a typed
// terminal cause.
type TerminalCauseClass int

const (
	// CauseClassLegacy: absent cause, engine_error, or an unknown value — the
	// historical string/status heuristics apply unchanged (legacy providers
	// must see zero behavior change).
	CauseClassLegacy TerminalCauseClass = iota
	// CauseClassFault: real provider sickness — full legacy fault behavior
	// (RecordJobFailure + every breaker funnel) applies.
	CauseClassFault
	// CauseClassNeutral: platform policy / client behavior — no fault
	// recorder, no breaker strike, no capacity outcome, and no clears either.
	CauseClassNeutral
	// CauseClassCapacity: the provider was healthy but busy — neutral for all
	// health breakers, recorded as a capacity-reject signal only.
	CauseClassCapacity
)

// ClassifyTerminalCause maps a wire terminal_cause to its health class.
// known is false ONLY for a non-empty value outside the closed vocabulary
// (vocabulary drift — callers emit MetricUnknownTerminalCause); the class is
// then CauseClassLegacy so drift can never change behavior.
func ClassifyTerminalCause(cause string) (class TerminalCauseClass, known bool) {
	switch cause {
	case "":
		return CauseClassLegacy, true
	case TerminalCauseAdmissionTimeout:
		return CauseClassCapacity, true
	case TerminalCauseSafetyDeadline, TerminalCauseBackpressureTimeout, TerminalCauseCancelled:
		return CauseClassNeutral, true
	case TerminalCausePrefillStall, TerminalCauseDecodeStall, TerminalCauseWatchdog:
		return CauseClassFault, true
	case TerminalCauseEngineError:
		return CauseClassLegacy, true
	default:
		return CauseClassLegacy, false
	}
}

// IsTypedTimeout504Cause reports whether cause is one of the KNOWN typed
// causes the provider maps to a 504 status (safety_deadline,
// backpressure_timeout). The dispatch wait loops use it to tell a typed
// provider 504 from a coordinator-synthesized timeout 504. An UNKNOWN
// future cause value deliberately does NOT count: consistent with
// ClassifyTerminalCause's unknown→legacy rule, an off-vocabulary 504 keeps
// the legacy synthetic-timeout route classification during mixed-version
// rollouts instead of being guessed into provider_error/admitted_but_failed.
func IsTypedTimeout504Cause(cause string) bool {
	return cause == TerminalCauseSafetyDeadline || cause == TerminalCauseBackpressureTimeout
}

// MetricTypedTerminal counts every provider inference_error terminal that
// carried a typed terminal_cause, tagged with the cause only (low
// cardinality: the 8 closed-vocabulary values plus "unknown"). Never tagged
// with request or provider IDs.
const MetricTypedTerminal = "inference.typed_terminal"

// MetricUnknownTerminalCause counts non-empty terminal_cause values outside
// the closed vocabulary — the vocabulary-drift alarm. Behavior for such
// terminals stays exactly legacy; this counter is how we notice a provider
// shipped a cause the coordinator does not understand yet.
const MetricUnknownTerminalCause = "inference.typed_terminal_unknown_cause"

// TypedTerminal classifies a wire terminal_cause and emits the typed
// terminal metrics exactly once per provider error terminal (call it only
// from handleInferenceError, the single provider-frame ingress). An empty
// cause is a legacy terminal: no metric, legacy class.
func (s Service) TypedTerminal(cause string) TerminalCauseClass {
	if cause == "" {
		return CauseClassLegacy
	}
	class, known := ClassifyTerminalCause(cause)
	tag := "cause:" + cause
	if !known {
		tag = "cause:unknown"
		s.deps.Metrics.Incr(MetricUnknownTerminalCause, nil)
	}
	s.deps.Metrics.Incr(MetricTypedTerminal, []string{tag})
	return class
}
