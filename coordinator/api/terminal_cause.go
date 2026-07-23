package api

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
	terminalCauseAdmissionTimeout    = "admission_timeout"
	terminalCausePrefillStall        = "prefill_stall"
	terminalCauseDecodeStall         = "decode_stall"
	terminalCauseSafetyDeadline      = "safety_deadline"
	terminalCauseBackpressureTimeout = "backpressure_timeout"
	terminalCauseWatchdog            = "watchdog"
	terminalCauseCancelled           = "cancelled"
	terminalCauseEngineError         = "engine_error"
)

// terminalCauseClass is the coordinator-side health classification of a typed
// terminal cause.
type terminalCauseClass int

const (
	// causeClassLegacy: absent cause, engine_error, or an unknown value — the
	// historical string/status heuristics apply unchanged (legacy providers
	// must see zero behavior change).
	causeClassLegacy terminalCauseClass = iota
	// causeClassFault: real provider sickness — full legacy fault behavior
	// (RecordJobFailure + every breaker funnel) applies.
	causeClassFault
	// causeClassNeutral: platform policy / client behavior — no fault
	// recorder, no breaker strike, no capacity outcome, and no clears either.
	causeClassNeutral
	// causeClassCapacity: the provider was healthy but busy — neutral for all
	// health breakers, recorded as a capacity-reject signal only.
	causeClassCapacity
)

// classifyTerminalCause maps a wire terminal_cause to its health class.
// known is false ONLY for a non-empty value outside the closed vocabulary
// (vocabulary drift — callers emit metricUnknownTerminalCause); the class is
// then causeClassLegacy so drift can never change behavior.
func classifyTerminalCause(cause string) (class terminalCauseClass, known bool) {
	switch cause {
	case "":
		return causeClassLegacy, true
	case terminalCauseAdmissionTimeout:
		return causeClassCapacity, true
	case terminalCauseSafetyDeadline, terminalCauseBackpressureTimeout, terminalCauseCancelled:
		return causeClassNeutral, true
	case terminalCausePrefillStall, terminalCauseDecodeStall, terminalCauseWatchdog:
		return causeClassFault, true
	case terminalCauseEngineError:
		return causeClassLegacy, true
	default:
		return causeClassLegacy, false
	}
}

// metricTypedTerminal counts every provider inference_error terminal that
// carried a typed terminal_cause, tagged with the cause only (low
// cardinality: the 8 closed-vocabulary values plus "unknown"). Never tagged
// with request or provider IDs.
const metricTypedTerminal = "inference.typed_terminal"

// metricUnknownTerminalCause counts non-empty terminal_cause values outside
// the closed vocabulary — the vocabulary-drift alarm. Behavior for such
// terminals stays exactly legacy; this counter is how we notice a provider
// shipped a cause the coordinator does not understand yet.
const metricUnknownTerminalCause = "inference.typed_terminal_unknown_cause"

// noteTypedTerminalCause classifies a wire terminal_cause and emits the typed
// terminal metrics exactly once per provider error terminal (call it only
// from handleInferenceError, the single provider-frame ingress). An empty
// cause is a legacy terminal: no metric, legacy class.
func (s *Server) noteTypedTerminalCause(cause string) terminalCauseClass {
	if cause == "" {
		return causeClassLegacy
	}
	class, known := classifyTerminalCause(cause)
	tag := "cause:" + cause
	if !known {
		tag = "cause:unknown"
		s.ddIncr(metricUnknownTerminalCause, nil)
	}
	s.ddIncr(metricTypedTerminal, []string{tag})
	return class
}
