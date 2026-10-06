// Package observation formats bounded operational App Attest events. Proof
// bytes and user content are retained only in the evidence archive, never here.
package observation

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type Event struct {
	Provider                                   *registry.Provider
	Session, Account, Version, OSVersion, Chip string
	Stage, Outcome                             string
	Serving                                    bool
	Dropped                                    uint64
	Started                                    time.Time
	Metadata                                   *appattest.Key
	ReadyContext, PolicyFields                 map[string]any
	Reply                                      protocol.AppAttestShadowPayload
}

type Formatted struct {
	Fields            map[string]any
	Tags              []string
	DurationMS        *float64
	MeasurementPolicy string
}

func Format(e Event) Formatted {
	fields := map[string]any{"inbox_dropped": e.Dropped, "event": "app_attest_shadow", "provider_id": e.Provider.ID, "shadow_session": e.Session,
		"stage": e.Stage, "outcome": e.Outcome, "mode": "shadow", "reported_version": Label(e.Version), "reported_os": Label(e.OSVersion), "reported_chip": Label(e.Chip)}
	mode := "shadow"
	if e.Serving {
		mode = "serving"
		fields["mode"] = mode
	}
	e.Provider.Mu().Lock()
	fields["legacy_trust"] = string(e.Provider.TrustLevel)
	fields["legacy_code_attested"] = e.Provider.CodeAttested
	fields["legacy_mda_verified"] = e.Provider.MDAVerified
	e.Provider.Mu().Unlock()
	r := Formatted{Fields: fields, Tags: []string{"stage:" + e.Stage, "outcome:" + e.Outcome, "mode:" + mode}}
	if !e.Started.IsZero() {
		elapsed := float64(time.Since(e.Started)) / float64(time.Millisecond)
		fields["duration_ms"], r.DurationMS = elapsed, &elapsed
	}
	if e.Metadata != nil {
		r.MeasurementPolicy = eligibility.AppendMeasurement(fields, e.Version, e.Metadata)
	}
	fields["account_id"] = e.Account
	if e.Reply.AppleError != nil && e.Reply.AppleError.Valid() {
		fields["apple_error"] = e.Reply.AppleError
	}
	if e.Reply.ValidClientDiagnostics() {
		if e.Reply.AvailabilityReason != "" {
			fields["availability_reason"] = e.Reply.AvailabilityReason
		}
		if e.Reply.AppleErrorSource != "" {
			fields["apple_error_source"] = e.Reply.AppleErrorSource
		}
	}
	if e.Stage == "attestation" || e.Stage == "assertion" {
		for key, value := range e.ReadyContext {
			fields[key] = value
		}
	}
	for key, value := range e.Reply.RuntimeDiagnosticFields(time.Now()) {
		fields[key] = value
	}
	if e.Stage == "prospective_policy" {
		for key, value := range e.PolicyFields {
			fields[key] = value
		}
	}
	return r
}

func Label(s string) string {
	if len(s) > 64 {
		return "oversized"
	}
	return s
}
