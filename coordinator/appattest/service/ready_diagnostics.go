package service

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Match the provider's boot-history tolerance: kern.boottime can move slightly
// when the Mac wall clock is adjusted. Larger adjustments remain ambiguous.
const diagnosticBootTimeTolerance = 60

// deriveKeyLifecycleDiagnostics compares provider-origin timestamps with the
// latest durably verified assertion's context, never a coordinator clock or key
// insertion time. Refresh before every proof so periodic assertions advance the
// baseline too. These optional fields never affect authorization or rotation.
func (x *Session) deriveKeyLifecycleDiagnostics(ctx context.Context) {
	ready := x.readyDiagnostics
	delete(ready, "rebooted_since_last_success")
	delete(ready, "process_restarted_since_last_success")
	if ready == nil || x.key == nil {
		return
	}
	current := protocol.AppAttestShadowPayload{Action: "ready"}
	current.BootTime, _ = ready["boot_time"].(int64)
	current.ProcessStartedAt, _ = ready["process_started_at"].(int64)
	now := time.Now()
	current.SanitizeRuntimeDiagnostics(now)
	if current.BootTime == 0 && current.ProcessStartedAt == 0 {
		return
	}
	reader, ok := store.As[store.AppAttestDiagnosticStore](x.archive)
	if !ok {
		return
	}
	// An optional lookup has its own small budget; errors leave unknown fields
	// and never become storage failures, dropped proofs, or authorization fences.
	lookup, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
	defer cancel()
	baseline, err := reader.GetAppAttestAssertionDiagnostics(lookup, x.key.KeyID)
	if err != nil || baseline == nil {
		return
	}
	prior := protocol.AppAttestShadowPayload{Action: "ready"}
	_ = json.Unmarshal(baseline.BootTime, &prior.BootTime)
	_ = json.Unmarshal(baseline.ProcessStartedAt, &prior.ProcessStartedAt)
	prior.SanitizeRuntimeDiagnostics(now)
	if current.BootTime != 0 && prior.BootTime != 0 {
		delta := current.BootTime - prior.BootTime
		ready["rebooted_since_last_success"] = delta > diagnosticBootTimeTolerance || delta < -diagnosticBootTimeTolerance
	}
	if current.ProcessStartedAt != 0 && prior.ProcessStartedAt != 0 {
		ready["process_restarted_since_last_success"] = current.ProcessStartedAt != prior.ProcessStartedAt
	}
}

// readyDiagnosticsFor returns this attempt's ready context for events of the
// proof stages, so a failed or verified attestation/assertion event carries the
// lifecycle and posture that preceded it.
func (x *Session) readyDiagnosticsFor(stage string) map[string]any {
	if stage != "attestation" && stage != "assertion" {
		return nil
	}
	return x.readyDiagnostics
}
