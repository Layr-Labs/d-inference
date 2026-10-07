// Package diagnostics derives optional, untrusted lifecycle context from
// durably verified provider-origin timestamps. It grants no serving trust.
package diagnostics

import (
	"context"
	"encoding/json"
	"time"

	storagebudget "github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const BootTimeTolerance = 60

// Derive clears stale flags before every proof. Optional lookup failures stay
// unknown and never become an archival failure or evidence-gap fence.
func Derive(ctx context.Context, budget *storagebudget.Budget, archive store.AppAttestArchiveStore, key *store.AppAttestShadowKey, ready map[string]any) {
	delete(ready, "rebooted_since_last_success")
	delete(ready, "process_restarted_since_last_success")
	if ready == nil || key == nil {
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
	reader, ok := store.As[store.AppAttestDiagnosticStore](archive)
	if !ok {
		return
	}
	release, ok := budget.AcquireDiagnostic()
	if !ok {
		return
	}
	defer release()
	lookup, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
	defer cancel()
	baseline, err := reader.GetAppAttestAssertionDiagnostics(lookup, key.KeyID)
	if err != nil || baseline == nil {
		return
	}
	prior := protocol.AppAttestShadowPayload{Action: "ready"}
	_ = json.Unmarshal(baseline.BootTime, &prior.BootTime)
	_ = json.Unmarshal(baseline.ProcessStartedAt, &prior.ProcessStartedAt)
	prior.SanitizeRuntimeDiagnostics(now)
	if current.BootTime != 0 && prior.BootTime != 0 {
		delta := current.BootTime - prior.BootTime
		ready["rebooted_since_last_success"] = delta > BootTimeTolerance || delta < -BootTimeTolerance
	}
	if current.ProcessStartedAt != 0 && prior.ProcessStartedAt != 0 && current.ProcessStartedAt != prior.ProcessStartedAt {
		ready["process_restarted_since_last_success"] = true
	}
}
