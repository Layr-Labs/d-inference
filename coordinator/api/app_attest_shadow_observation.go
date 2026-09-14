package api

import (
	"context"
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (x *appAttestShadowSession) observe(stage, outcome string, metadata *appattest.Key) {
	if x.evidenceID != "" && stage != "archive" {
		x.evidenceOutcome = outcome
	}
	fields := map[string]any{"inbox_dropped": x.dropped.Load(), "event": "app_attest_shadow", "provider_id": x.provider.ID, "shadow_session": x.id,
		"stage": stage, "outcome": outcome, "mode": "shadow", "reported_version": boundedShadowLabel(x.version),
		"reported_os": boundedShadowLabel(x.osVersion), "reported_chip": boundedShadowLabel(x.chip)}
	x.provider.Mu().Lock()
	fields["legacy_trust"] = string(x.provider.TrustLevel)
	fields["legacy_code_attested"] = x.provider.CodeAttested
	fields["legacy_mda_verified"] = x.provider.MDAVerified
	x.provider.Mu().Unlock()
	tags := []string{"stage:" + stage, "outcome:" + outcome, "mode:shadow"}
	if !x.started.IsZero() {
		elapsed := float64(time.Since(x.started)) / float64(time.Millisecond)
		fields["duration_ms"] = elapsed
		x.s.ddHistogram("app_attest.shadow.duration_ms", elapsed, tags)
	}
	if metadata != nil {
		policy := "matched"
		if metadata.ValidationCategory == nil || metadata.BundleVersion == "" {
			policy = "metadata_missing"
		} else if *metadata.ValidationCategory != 6 || metadata.BundleVersion != x.version {
			policy = "metadata_mismatch"
		}
		fields["metadata_comparison"] = policy
		fields["attested_bundle_version"] = metadata.BundleVersion
		if metadata.ValidationCategory != nil {
			fields["attested_validation_category"] = *metadata.ValidationCategory
		}
		x.s.ddIncr("app_attest.shadow.metadata", []string{"result:" + policy})
	}
	fields["account_id"] = x.account
	if x.inventory != nil {
		identity := x.inventory.snapshot()
		fields["machine_id"] = identity.ID
		fields["identity_assurance"] = identity.Assurance
		raw, _ := json.Marshal(fields)
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		err := x.inventory.store.RecordAppAttestEvent(ctx, store.AppAttestEvent{ID: uuid.NewString(), SessionID: x.provider.ID, At: time.Now().UTC(), Stage: stage, Outcome: outcome, Fields: raw})
		cancel()
		if err != nil {
			x.s.ddIncr("app_attest.events.storage_failed", nil)
		}
	}
	x.s.ddIncr("app_attest.shadow.events", tags)
	x.s.emit(nil, protocol.SeverityInfo, protocol.KindCustom, "App Attest shadow observation", fields)
}

func boundedShadowLabel(s string) string {
	if len(s) > 64 {
		return "oversized"
	}
	return s
}
