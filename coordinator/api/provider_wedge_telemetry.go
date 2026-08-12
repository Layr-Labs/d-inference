package api

// Coordinator-side observability for the provider first-token "wedge"
// (docs/reports/2026-06-22-cancel-root-cause-and-fix.md §C). The provider
// reports engine-health counters on every heartbeat via BackendSlotCapacity;
// this turns the wedge-suspected signal into a Datadog counter so operators can
// SEE a wedge fleet-wide straight from heartbeats — independent of, and more
// reliable than, the provider's telemetry-event trail (heartbeats always flow).
//
// MEASUREMENT ONLY: nothing here changes routing. The follow-up breaker/watchdog
// work consumes the same signals (also decoded into registry.routingSnapshot).

import "github.com/eigeninference/d-inference/coordinator/protocol"

// evalInFlightLongMs is the threshold (ms) above which a heartbeat-reported
// in-flight eval is treated as a developing first-token wedge. Well above a
// normal eval (sub-ms..ms) and below the ~10s OpenRouter TTFT SLA, so it catches
// the stall while it is still hanging.
const evalInFlightLongMs = 2000

// backendWedgeSignal is the per-slot engine-health view extracted from a
// heartbeat. Kept as a small pure value so the extraction is table-testable
// without a live Server / Datadog client.
type backendWedgeSignal struct {
	Model                string
	StepsExecuted        int64
	Admits               int64
	FirstTokensEmitted   int64
	SecondsSinceLastStep float64
	WedgeSuspected       bool
	EvalInFlightMs       int64
	IdleClearInFlightMs  int64
}

// backendWedgeSignals extracts the engine-health signals from a heartbeat,
// skipping slots that report none. A pre-instrumentation provider (and a
// freshly-idle slot that has never served) reports all zeros/false, so it
// produces no signal — keeping the metric clean as the instrumented build rolls
// out across the fleet.
func backendWedgeSignals(capacity *protocol.BackendCapacity) []backendWedgeSignal {
	if capacity == nil || len(capacity.Slots) == 0 {
		return nil
	}
	out := make([]backendWedgeSignal, 0, len(capacity.Slots))
	for _, slot := range capacity.Slots {
		if slot.StepsExecuted == 0 && slot.Admits == 0 && !slot.WedgeSuspected &&
			slot.EvalInFlightMs == 0 && slot.IdleClearInFlightMs == 0 {
			continue
		}
		out = append(out, backendWedgeSignal{
			Model:                slot.Model,
			StepsExecuted:        slot.StepsExecuted,
			Admits:               slot.Admits,
			FirstTokensEmitted:   slot.FirstTokensEmitted,
			SecondsSinceLastStep: slot.SecondsSinceLastStep,
			WedgeSuspected:       slot.WedgeSuspected,
			EvalInFlightMs:       slot.EvalInFlightMs,
			IdleClearInFlightMs:  slot.IdleClearInFlightMs,
		})
	}
	return out
}

// providerWideEvalInFlightLong reports whether a blocking eval has been running
// past the "long" threshold. `eval_in_flight_ms` comes from the process-global
// MLX EvalProbe (one evalLock for the whole provider) and is copied onto EVERY
// slot, so it is a PROVIDER-WIDE fact, not a per-model one — the decision is made
// once from the max across slots so the metric fires at most once per heartbeat
// (a per-slot loop would over-count it once per loaded model and falsely tag idle
// models as stalled).
func providerWideEvalInFlightLong(sigs []backendWedgeSignal) bool {
	var maxMs int64
	for _, sig := range sigs {
		if sig.EvalInFlightMs > maxMs {
			maxMs = sig.EvalInFlightMs
		}
	}
	return maxMs >= evalInFlightLongMs
}

// recordBackendWedgeTelemetry emits Datadog signals from a heartbeat. Called from
// the heartbeat handler; no-op for legacy/idle providers (no signals extracted).
//   - provider.first_token_wedge_suspected: PER-MODEL (genuinely per-scheduler).
//   - provider.eval_in_flight_long: PROVIDER-WIDE, at most once per heartbeat
//     (the eval probe is process-global; see providerWideEvalInFlightLong).
func (s *Server) recordBackendWedgeTelemetry(capacity *protocol.BackendCapacity) {
	sigs := backendWedgeSignals(capacity)
	for _, sig := range sigs {
		if sig.WedgeSuspected {
			s.ddIncr("provider.first_token_wedge_suspected", []string{"model:" + sig.Model})
		}
	}
	// The blocking eval is the direct wedge smoking gun (stuck inside mlx_eval
	// under the one global evalLock). Emit it provider-wide, untagged by model.
	if providerWideEvalInFlightLong(sigs) {
		s.ddIncr("provider.eval_in_flight_long", nil)
	}
}
