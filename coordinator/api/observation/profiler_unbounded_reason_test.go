package observation

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestDeadlineUnboundedReasonStoredWithoutInventingHistoricalCause(t *testing.T) {
	for _, tc := range []struct {
		name, field string
		want        protocol.DeadlineUnboundedReason
		folded      bool
	}{
		{"legacy", "", "", false},
		{"missing rate", `,"unbounded_reason":"decode_rate_unavailable"`, protocol.DeadlineUnboundedDecodeRateUnavailable, false},
		{"capacity", `,"unbounded_reason":"capacity_not_guaranteed"`, protocol.DeadlineUnboundedCapacityNotGuaranteed, false},
		{"future", `,"unbounded_reason":"PROVIDER_FREE_TEXT"`, protocol.DeadlineUnboundedOther, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			raw := []byte(`{"schema":1,"deadline_decision":{"verdict":"deadline_unreachable","projection":"unbounded"` + tc.field + `}}`)
			stored, valid, reason, folded := decodeInferenceProfile(raw, fixtureReceivedAt)
			if !valid || folded != tc.folded || stored.DeadlineDecision == nil {
				t.Fatalf("valid=%v reason=%s folded=%v", valid, reason, folded)
			}
			d := stored.DeadlineDecision
			if d.UnboundedReason != tc.want || d.ProjectionReason != "" || d.ProjectedServiceUS != nil || d.ProjectedPrefillTokens != nil {
				t.Fatalf("incorrect reason or invented evidence: %+v", d)
			}
			encoded, err := json.Marshal(stored)
			if err != nil || bytes.Contains(encoded, []byte("PROVIDER_FREE_TEXT")) {
				t.Fatalf("unsafe stored profile: %s %v", encoded, err)
			}
			if tc.want == "" && bytes.Contains(encoded, []byte("unbounded_reason")) {
				t.Fatalf("legacy reason must be omitted: %s", encoded)
			}
		})
	}
}

func TestDeadlineUnboundedReasonRetainsAttemptOwnership(t *testing.T) {
	srv := newProviderProfileTestServer(nil)
	rp := registry.NewRequestProfile(fixtureReceivedAt, "logical-request", nil, 0)
	for i, want := range []protocol.DeadlineUnboundedReason{
		protocol.DeadlineUnboundedInconsistentTokenCursor,
		protocol.DeadlineUnboundedCapacityNotGuaranteed,
	} {
		ap := rp.NewAttempt([]string{"primary", "retry"}[i], i, "")
		schema := protocol.InferenceProfileSchema
		raw, err := json.Marshal(protocol.InferenceProfile{
			Schema: &schema,
			DeadlineDecision: &protocol.DeadlineDecision{
				Verdict: protocol.DeadlineVerdictUnreachable, Projection: protocol.DeadlineProjectionUnbounded,
				UnboundedReason: want,
			},
		})
		if err != nil {
			t.Fatal(err)
		}
		if ap.SetProviderProfileRaw(raw) != registry.ProviderProfileStored {
			t.Fatal("profile not retained")
		}
		record := srv.buildProfileRecord(rp, ap)
		var stored StoredInferenceProfile
		if err := json.Unmarshal(record.ProviderProfile, &stored); err != nil || stored.DeadlineDecision == nil ||
			stored.DeadlineDecision.UnboundedReason != want || record.RequestID != ap.RequestID || !record.ProviderProfileValid {
			t.Fatalf("attempt %d lost reason: %s %v", i, record.ProviderProfile, err)
		}
	}
}
