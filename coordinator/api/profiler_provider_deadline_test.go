package api

import (
	"bytes"
	"encoding/json"
	"math"
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestDeadlineDecisionOldProfilesKeepUnknownAbsent(t *testing.T) {
	for _, raw := range []string{
		`{"schema":1}`,
		`{"schema":1,"engine_submit_us":100,"engine_admitted_us":120,"projected_service_us":800}`,
	} {
		stored, valid, reason, _ := decodeInferenceProfile([]byte(raw), fixtureReceivedAt)
		if !valid || stored.DeadlineDecision != nil {
			t.Fatalf("old profile gained a decision: stored=%+v reason=%q", stored, reason)
		}
		encoded, err := json.Marshal(stored)
		if err != nil || bytes.Contains(encoded, []byte("deadline_decision")) {
			t.Fatalf("missing decision must remain omitted: %s %v", encoded, err)
		}
	}
}

func TestDeadlineDecisionRetainsRefusalAndAcceptanceBeforeExpiry(t *testing.T) {
	for _, tc := range []struct {
		frame        string
		verdict      protocol.DeadlineVerdict
		continuation protocol.DeadlineContinuation
		remaining    int64
	}{
		{"inference_error_deadline", protocol.DeadlineVerdictUnreachable, "", 88000},
		{"inference_error_accepted_expired", protocol.DeadlineVerdictAccepted, protocol.DeadlineContinuationExpired, 0},
	} {
		t.Run(tc.frame, func(t *testing.T) {
			p, valid, reason, folded := decodeInferenceProfile(fixtureProfile(t, tc.frame), fixtureReceivedAt)
			if !valid || folded || p.DeadlineDecision == nil {
				t.Fatalf("decision rejected: valid=%v reason=%q folded=%v", valid, reason, folded)
			}
			d := p.DeadlineDecision
			if d.Verdict != tc.verdict || d.Continuation != tc.continuation || d.RemainingUS == nil || *d.RemainingUS != tc.remaining {
				t.Fatalf("wrong decision: %+v", d)
			}
			if p.EngineAdmittedUS != nil || p.ProjectedServiceUS != nil || p.BudgetRemainingAtAdmitUS != nil {
				t.Fatalf("decision receipt fabricated an old acceptance stamp or measurement: %+v", p)
			}
		})
	}
}

func TestDeadlineDecisionUnknownEnumsAndFieldsNeverPersistFreeText(t *testing.T) {
	raw := []byte(`{"schema":1,"deadline_decision":{"verdict":"VERDICT_LEAK","continuation":"CONTINUATION_LEAK","projection":"PROJECTION_LEAK","projection_reason":"REASON_LEAK","observed_us":0,"remaining_us":0,"prefill_tps":0,"note":"NOTE_LEAK","prompt":{"text":"PROMPT_LEAK"}}}`)
	p, valid, reason, folded := decodeInferenceProfile(raw, fixtureReceivedAt)
	if !valid || !folded || p == nil || p.DeadlineDecision == nil {
		t.Fatalf("future enum invalidated record: valid=%v reason=%q folded=%v", valid, reason, folded)
	}
	d := p.DeadlineDecision
	if d.Verdict != protocol.DeadlineVerdictOther || d.Continuation != protocol.DeadlineContinuationOther ||
		d.Projection != protocol.DeadlineProjectionOther || d.ProjectionReason != protocol.DeadlineProjectionReasonOther {
		t.Fatalf("unknown enum not folded: %+v", d)
	}
	encoded, err := json.Marshal(p)
	if err != nil || bytes.Contains(encoded, []byte("LEAK")) || bytes.Contains(encoded, []byte("prompt")) || bytes.Contains(encoded, []byte("note")) {
		t.Fatalf("provider text escaped allowlist: %s %v", encoded, err)
	}
	if d.ObservedUS == nil || *d.ObservedUS != 0 || d.RemainingUS == nil || *d.RemainingUS != 0 || d.PrefillTPS == nil || *d.PrefillTPS != 0 {
		t.Fatalf("explicit zero lost: %+v", d)
	}
	if d.SubmitRemainingUS != nil || d.ProjectedServiceUS != nil || d.DecodeTPS != nil || d.ProjectedPrefillTokens != nil {
		t.Fatalf("absent number fabricated: %+v", d)
	}
}

func TestDeadlineDecisionInvalidRangesAndOrdering(t *testing.T) {
	cases := []struct{ name, profile, reason string }{
		{"negative observed", `"deadline_decision":{"observed_us":-1}`, profileInvalidRange},
		{"observed over hour", `"deadline_decision":{"observed_us":3600000001}`, profileInvalidRange},
		{"negative remaining", `"deadline_decision":{"remaining_us":-1}`, profileInvalidRange},
		{"submit remaining over hour", `"deadline_decision":{"submit_remaining_us":3600000001}`, profileInvalidRange},
		{"projected service over hour", `"deadline_decision":{"projected_service_us":3600000001}`, profileInvalidRange},
		{"negative prefill tokens", `"deadline_decision":{"projected_prefill_tokens":-1}`, profileInvalidRange},
		{"decode tokens over bound", `"deadline_decision":{"projected_decode_tokens":1000000001}`, profileInvalidRange},
		{"negative prefill rate", `"deadline_decision":{"prefill_tps":-0.5}`, profileInvalidRange},
		{"decode rate over bound", `"deadline_decision":{"decode_tps":1000000001}`, profileInvalidRange},
		{"overflow rate", `"deadline_decision":{"decode_tps":1e309}`, profileInvalidDecode},
		{"rate string", `"deadline_decision":{"prefill_tps":"RATE_LEAK"}`, profileInvalidDecode},
		{"object string", `"deadline_decision":"OBJECT_LEAK"`, profileInvalidDecode},
		{"verdict observed before submit", `"engine_submit_us":10,"deadline_decision":{"verdict":"deadline_unreachable","observed_us":9}`, profileInvalidOrder},
		{"accepted observed before submit", `"engine_submit_us":10,"deadline_decision":{"verdict":"accepted","observed_us":9}`, profileInvalidOrder},
		{"observed after terminal total", `"total_us":10,"deadline_decision":{"observed_us":11}`, profileInvalidOrder},
		{"budget grew", `"deadline_decision":{"submit_remaining_us":10,"remaining_us":11}`, profileInvalidOrder},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p, valid, reason, _ := decodeInferenceProfile([]byte(`{"schema":1,`+tc.profile+`}`), fixtureReceivedAt)
			if valid || reason != tc.reason {
				t.Fatalf("valid=%v reason=%q, want %q", valid, reason, tc.reason)
			}
			if reason == profileInvalidDecode && p != nil {
				t.Fatalf("undecodable profile retained: %+v", p)
			}
			if p != nil {
				encoded, err := json.Marshal(p)
				if err != nil || strings.Contains(string(encoded), "LEAK") {
					t.Fatalf("invalid diagnostic data not safe to store: %s %v", encoded, err)
				}
			}
		})
	}
	for _, raw := range []string{
		`{"schema":1,"deadline_decision":{"verdict":"expired_before_submit","observed_us":0,"remaining_us":0}}`,
		`{"schema":1,"deadline_decision":{"verdict":"accepted","projection":"unbounded"}}`,
		`{"schema":1,"deadline_decision":{"verdict":"accepted","projection":"not_attempted","projection_reason":"mode_off"}}`,
	} {
		_, valid, reason, _ := decodeInferenceProfile([]byte(raw), fixtureReceivedAt)
		if !valid {
			t.Fatalf("partial decision rejected: %s reason=%q", raw, reason)
		}
	}
}

func TestDeadlineDecisionRateBoundsAndDetachedStorage(t *testing.T) {
	for _, tc := range []struct {
		input, want float64
		invalid     bool
	}{
		{0, 0, false}, {0.125, 0.125, false}, {maxProfileTPS, maxProfileTPS, false},
		{-1, 0, true}, {math.NaN(), 0, true}, {math.Inf(-1), 0, true},
		{math.Inf(1), maxProfileTPS, true}, {maxProfileTPS + 1, maxProfileTPS, true},
	} {
		var b profileBounds
		got := b.tps(&tc.input)
		if got == nil || *got != tc.want || b.violated != tc.invalid || got == &tc.input {
			t.Fatalf("rate %v: got=%v violated=%v", tc.input, got, b.violated)
		}
	}
	var b profileBounds
	if b.tps(nil) != nil {
		t.Fatal("absent rate became zero")
	}
	observed, remaining, submit, service := int64(10), int64(20), int64(30), int64(40)
	prefill, decode, prefillTPS, decodeTPS := 50, 60, 70.5, 80.5
	w := &protocol.DeadlineDecision{ObservedUS: &observed, RemainingUS: &remaining, SubmitRemainingUS: &submit,
		ProjectedServiceUS: &service, ProjectedPrefillTokens: &prefill, ProjectedDecodeTokens: &decode,
		PrefillTPS: &prefillTPS, DecodeTPS: &decodeTPS}
	stored, _ := storeDeadlineDecision(w, &b)
	before, _ := json.Marshal(stored)
	observed, remaining, submit, service, prefill, decode, prefillTPS, decodeTPS = 1, 1, 1, 1, 1, 1, 1, 1
	after, _ := json.Marshal(stored)
	if !bytes.Equal(before, after) {
		t.Fatalf("stored decision aliases wire values: before=%s after=%s", before, after)
	}
}

func TestDeadlineDecisionStaysWithItsAttemptAcrossRetryAndBackup(t *testing.T) {
	srv := newProviderProfileTestServer(nil)
	rp := registry.NewRequestProfile(fixtureReceivedAt, "logical-request", nil, 0)
	primary := rp.NewAttempt("primary", 0, "")
	retry := rp.NewAttempt("retry", 1, "")
	backup := rp.NewAttempt("backup", 1, "retry")
	attempts := []*registry.AttemptProfile{primary, retry, backup}
	frames := []string{"inference_error_deadline", "inference_error_accepted_expired", "inference_complete_full"}
	wantVerdicts := []protocol.DeadlineVerdict{protocol.DeadlineVerdictUnreachable, protocol.DeadlineVerdictAccepted, protocol.DeadlineVerdictAccepted}
	for i, ap := range attempts {
		ap.ProviderID = []string{"provider-a", "provider-b", "provider-c"}[i]
		if got := ap.SetProviderProfileRaw(fixtureProfile(t, frames[i])); got != registry.ProviderProfileStored {
			t.Fatalf("retain attempt %d: %v", i, got)
		}
	}
	backup.Winning.Store(true)
	for i, ap := range attempts {
		rec := srv.buildProfileRecord(rp, ap)
		if rec.CoordRequestID != "logical-request" || rec.RequestID != ap.RequestID || rec.Attempt != ap.Attempt ||
			rec.BackupOf != ap.BackupOf || rec.ProviderID != ap.ProviderID || rec.Winning != (i == 2) || !rec.ProviderProfileValid {
			t.Fatalf("attempt identity or validity lost: %+v", rec)
		}
		var got StoredInferenceProfile
		if err := json.Unmarshal(rec.ProviderProfile, &got); err != nil || got.DeadlineDecision == nil || got.DeadlineDecision.Verdict != wantVerdicts[i] {
			t.Fatalf("attempt %d got wrong decision: %s %v", i, rec.ProviderProfile, err)
		}
		if i < 2 && rec.ProvEngineAdmittedUS != nil {
			t.Fatalf("attempt %d acquired another attempt's engine stamp", i)
		}
		if i == 1 && got.DeadlineDecision.Continuation != protocol.DeadlineContinuationExpired {
			t.Fatalf("retry lost accepted-then-expired distinction: %+v", got.DeadlineDecision)
		}
	}
}

func TestDeadlineDecisionFullProfileNumericBoundsFitWireCap(t *testing.T) {
	var wire protocol.InferenceProfile
	if err := json.Unmarshal(fixtureProfile(t, "inference_complete_full"), &wire); err != nil {
		t.Fatal(err)
	}
	// A full successful profile, with every present duration/count/byte/rate
	// at its numeric limit, still has headroom for the extra decision fields.
	var fillMax func(reflect.Value)
	fillMax = func(v reflect.Value) {
		for i := 0; i < v.NumField(); i++ {
			field, meta := v.Field(i), v.Type().Field(i)
			if field.Kind() != reflect.Ptr || field.IsNil() || meta.Name == "Schema" || meta.Name == "WallMS" {
				continue
			}
			e := field.Elem()
			switch e.Kind() {
			case reflect.Struct:
				fillMax(e)
			case reflect.Int:
				e.SetInt(int64(maxProfileCount))
			case reflect.Int64:
				limit := maxProfileUS
				if strings.HasSuffix(meta.Name, "NS") || strings.Contains(meta.Name, "NS") {
					limit = maxProfileNS
				} else if strings.Contains(meta.Name, "Bytes") {
					limit = maxProfileBytes
				}
				e.SetInt(limit)
			case reflect.Float64:
				e.SetFloat(maxProfileTPS)
			}
		}
	}
	fillMax(reflect.ValueOf(&wire).Elem())
	raw, err := json.Marshal(wire)
	if err != nil || len(raw) > protocol.MaxInferenceProfileBytes {
		t.Fatalf("full profile exceeds cap: bytes=%d err=%v", len(raw), err)
	}
	_, valid, reason, _ := decodeInferenceProfile(raw, fixtureReceivedAt)
	if !valid {
		t.Fatalf("maximum in-range fixture rejected: reason=%q", reason)
	}
	t.Logf("full profile at numeric limits: %d / %d bytes", len(raw), protocol.MaxInferenceProfileBytes)
}
