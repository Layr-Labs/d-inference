package service

import (
	"github.com/eigeninference/d-inference/coordinator/store"
)

// deriveKeyLifecycleDiagnostics adds analysis fields that need no new wire
// data: whether the Mac rebooted, or the provider process restarted, after the
// stored key's last verified assertion (UpdatedAt; the insert time for a key
// that never asserted). Each is set only when both instants are known. Like
// the ready diagnostics they derive from, these are untrusted context and are
// never read by authorization or rotation decisions.
func deriveKeyLifecycleDiagnostics(ready map[string]any, key *store.AppAttestShadowKey) {
	if ready == nil || key == nil || key.UpdatedAt.IsZero() {
		return
	}
	lastSuccess := key.UpdatedAt.Unix()
	if boot, ok := ready["boot_time"].(int64); ok {
		ready["rebooted_since_last_success"] = boot > lastSuccess
	}
	if started, ok := ready["process_started_at"].(int64); ok {
		ready["process_restarted_since_last_success"] = started > lastSuccess
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
