package service

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (x *Session) observe(stage, outcome string, metadata *appattest.Key) {
	x.observeWithClientDiagnostics(stage, outcome, metadata, protocol.AppAttestShadowPayload{})
}

func (x *Session) observeWithClientDiagnostics(stage, outcome string, metadata *appattest.Key, reply protocol.AppAttestShadowPayload) {
	if stage != "archive" {
		x.lastOutcome = outcome
	}
	if x.evidenceID != "" && stage != "archive" {
		x.evidenceOutcome = outcome
	}
	fields := map[string]any{"inbox_dropped": x.dropped.Load(), "event": "app_attest_shadow", "provider_id": x.provider.ID, "shadow_session": x.id,
		"stage": stage, "outcome": outcome, "mode": "shadow", "reported_version": boundedShadowLabel(x.version),
		"reported_os": boundedShadowLabel(x.osVersion), "reported_chip": boundedShadowLabel(x.chip)}
	mode := "shadow"
	if x.s.authorizer != nil {
		mode = "serving"
		fields["mode"] = mode
	}
	x.provider.Mu().Lock()
	fields["legacy_trust"] = string(x.provider.TrustLevel)
	fields["legacy_code_attested"] = x.provider.CodeAttested
	fields["legacy_mda_verified"] = x.provider.MDAVerified
	x.provider.Mu().Unlock()
	tags := []string{"stage:" + stage, "outcome:" + outcome, "mode:" + mode}
	if !x.started.IsZero() {
		elapsed := float64(time.Since(x.started)) / float64(time.Millisecond)
		fields["duration_ms"] = elapsed
		x.s.ddHistogram("app_attest.shadow.duration_ms", elapsed, tags)
	}
	if metadata != nil {
		policy := "matched"
		candidate := metadata.CodeDirectorySHA256Candidate()
		if metadata.ValidationCategory == nil || metadata.BundleVersion == "" && len(candidate) == 0 {
			policy = "metadata_missing"
		} else if *metadata.ValidationCategory != 6 || metadata.BundleVersion != "" && metadata.BundleVersion != x.version {
			policy = "metadata_mismatch"
		} else if len(candidate) == 20 {
			// The signed 20-byte CDHash still needs a unique durable full-hash
			// qualification. Do not label it a complete metadata match here.
			policy = "truncated_measurement_pending_qualification"
		}
		fields["metadata_comparison"] = policy
		fields["attested_bundle_version"] = metadata.BundleVersion
		if metadata.ValidationCategory != nil {
			fields["attested_validation_category"] = *metadata.ValidationCategory
		}
		if metadata.CodeDirectoryType != nil {
			fields["attested_code_directory_type"] = *metadata.CodeDirectoryType
			fields["attested_code_directory_hash"] = hex.EncodeToString(metadata.CodeDirectoryHash)
			if len(candidate) == 20 {
				fields["attested_code_directory_hash_format"] = "sha256_prefix_20"
			} else if len(candidate) == 32 {
				fields["attested_code_directory_hash_format"] = "sha256_full_32"
			}
		}
		x.s.ddIncr("app_attest.shadow.metadata", []string{"result:" + policy})
	}
	fields["account_id"] = x.account
	if reply.AppleError != nil && reply.AppleError.Valid() {
		fields["apple_error"] = reply.AppleError
	}
	if reply.ValidClientDiagnostics() {
		if reply.AvailabilityReason != "" {
			fields["availability_reason"] = reply.AvailabilityReason
		}
		if reply.AppleErrorSource != "" {
			fields["apple_error_source"] = reply.AppleErrorSource
		}
	}
	for key, value := range reply.RuntimeDiagnosticFields(time.Now()) {
		fields[key] = value
	}
	if stage == "prospective_policy" {
		for key, value := range x.policyFields {
			fields[key] = value
		}
	}
	if x.inventory != nil {
		identity := x.inventory.snapshot()
		fields["machine_id"] = identity.ID
		fields["identity_assurance"] = identity.Assurance
		if release, ok := x.acquireStorage(); ok {
			raw, _ := json.Marshal(fields)
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			err := x.inventory.store.RecordAppAttestEvent(ctx, store.AppAttestEvent{ID: uuid.NewString(), SessionID: x.provider.ID, At: time.Now().UTC(), Stage: stage, Outcome: outcome, Fields: raw})
			cancel()
			release()
			if err != nil {
				x.s.ddIncr("app_attest.events.storage_failed", nil)
			}
		} else {
			fields["event_storage"] = "busy"
			x.s.ddIncr("app_attest.events.storage_failed", []string{"reason:busy"})
		}
	}
	x.s.ddIncr("app_attest.shadow.events", tags)
	x.s.emit(fields)
}

func boundedShadowLabel(s string) string {
	if len(s) > 64 {
		return "oversized"
	}
	return s
}
