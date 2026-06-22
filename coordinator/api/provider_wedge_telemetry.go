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
func backendWedgeSignals(hb *protocol.HeartbeatMessage) []backendWedgeSignal {
	if hb == nil || hb.BackendCapacity == nil {
		return nil
	}
	out := make([]backendWedgeSignal, 0, len(hb.BackendCapacity.Slots))
	for _, slot := range hb.BackendCapacity.Slots {
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

// recordBackendWedgeTelemetry emits a Datadog counter for each slot that reports
// a suspected first-token wedge, tagged by model. Called from the heartbeat
// handler. No-op for legacy/idle providers (backendWedgeSignals returns empty).
func (s *Server) recordBackendWedgeTelemetry(hb *protocol.HeartbeatMessage) {
	for _, sig := range backendWedgeSignals(hb) {
		if sig.WedgeSuspected {
			s.ddIncr("provider.first_token_wedge_suspected", []string{"model:" + sig.Model})
		}
		// A blocking eval still running past the threshold is the direct wedge
		// smoking gun (the provider is stuck inside mlx_eval under evalLock).
		if sig.EvalInFlightMs >= evalInFlightLongMs {
			s.ddIncr("provider.eval_in_flight_long", []string{"model:" + sig.Model})
		}
	}
}
