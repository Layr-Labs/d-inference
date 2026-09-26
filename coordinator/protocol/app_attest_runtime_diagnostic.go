package protocol

import "time"

// Earliest accepted boot_time (2020-01-01T00:00:00Z); Apple Silicon Macs
// cannot report an earlier boot. Values after now plus one day of clock skew
// are also invalid.
const (
	appAttestMinBootTime          = 1577836800
	appAttestMaxBootTimeSkew      = 24 * time.Hour
	AppAttestMaxOperationStallSec = 86400
)

// SanitizeRuntimeDiagnostics clears launch_session, boot_time,
// operation_stalled_seconds and every deep diagnostic member (see
// app_attest_deep_diagnostic.go) whose value is out of range or misplaced.
// Unlike ValidClientDiagnostics, an invalid value never rejects the frame or
// fences a lease: these optional fields are untrusted context, and an older
// coordinator ignores them entirely.
func (p *AppAttestShadowPayload) SanitizeRuntimeDiagnostics(now time.Time) {
	p.sanitizeDeepDiagnostics(now)
	if p.Action != "ready" {
		p.LaunchSession, p.BootTime, p.OperationStalledSeconds = "", 0, 0
		return
	}
	switch p.LaunchSession {
	case "", "gui", "background", "unknown":
	default:
		p.LaunchSession = ""
	}
	if p.BootTime != 0 && !validAppAttestTimestamp(p.BootTime, now) {
		p.BootTime = 0
	}
	if p.OperationStalledSeconds != 0 && (p.Result != "busy" || p.OperationStalledSeconds < 1 || p.OperationStalledSeconds > AppAttestMaxOperationStallSec) {
		p.OperationStalledSeconds = 0
	}
}

// RuntimeDiagnosticFields returns the sanitized non-empty values for the
// evidence context and observation event. It sanitizes its own copy, so direct
// callers that bypassed admission cannot leak out-of-range values.
func (p AppAttestShadowPayload) RuntimeDiagnosticFields(now time.Time) map[string]any {
	p.SanitizeRuntimeDiagnostics(now)
	fields := map[string]any{}
	if p.LaunchSession != "" {
		fields["launch_session"] = p.LaunchSession
	}
	if p.BootTime != 0 {
		fields["boot_time"] = p.BootTime
	}
	if p.OperationStalledSeconds != 0 {
		fields["operation_stalled_seconds"] = p.OperationStalledSeconds
	}
	p.addDeepDiagnosticFields(fields)
	return fields
}
