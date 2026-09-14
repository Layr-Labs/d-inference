package profiler

import (
	"crypto/rand"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestProfilerSamplingIsDeterministicPerLogicalRequest(t *testing.T) {
	p := &Profiler{enabled: true, sampleRate: 0.5}
	a, b := p.sampled("coord-abc"), p.sampled("coord-abc")
	if a != b {
		t.Fatal("sampling must be deterministic on the coordinator-minted id")
	}
	if !(&Profiler{sampleRate: 1}).sampled("x") || (&Profiler{sampleRate: 0}).sampled("x") {
		t.Fatal("rate 1 keeps everything, rate 0 keeps nothing")
	}
	if !(&Profiler{sampleRate: 0}).sampled("") {
		t.Fatal("a missing id is always kept")
	}
	kept := 0
	for i := 0; i < 2000; i++ {
		if (&Profiler{sampleRate: 0.1}).sampled(newRequestID()) {
			kept++
		}
	}
	if kept < 120 || kept > 300 {
		t.Fatalf("10%% sample kept %d of 2000", kept)
	}
}

func TestProfilerAlwaysRecordPredicates(t *testing.T) {
	p := &Profiler{enabled: true, sampleRate: 0}
	slow := int64(6 * time.Second / time.Microsecond)
	cases := []struct {
		name string
		rec  store.RequestProfileRecord
		want bool
	}{
		{"plain success", store.RequestProfileRecord{FinalStatus: finalStatusSuccess, ProviderProfileInvalidReason: providerProfileAbsent}, false},
		{"error", store.RequestProfileRecord{FinalStatus: "error", ProviderProfileInvalidReason: providerProfileAbsent}, true},
		{"slow first content", store.RequestProfileRecord{FinalStatus: finalStatusSuccess, FirstContentUS: &slow, ProviderProfileInvalidReason: providerProfileAbsent}, true},
		{"retried", store.RequestProfileRecord{FinalStatus: finalStatusSuccess, AttemptsTotal: 2, ProviderProfileInvalidReason: providerProfileAbsent}, true},
		{"backup", store.RequestProfileRecord{FinalStatus: finalStatusSuccess, BackupLaunched: true, ProviderProfileInvalidReason: providerProfileAbsent}, true},
		{"anomaly", store.RequestProfileRecord{FinalStatus: finalStatusSuccess, TimingAnomaly: true, ProviderProfileInvalidReason: providerProfileAbsent}, true},
		{"client gone", store.RequestProfileRecord{FinalStatus: finalStatusSuccess, ClientGonePhase: "after_commit", ProviderProfileInvalidReason: providerProfileAbsent}, true},
		{"invalid provider profile", store.RequestProfileRecord{FinalStatus: finalStatusSuccess, ProviderProfileInvalidReason: "range"}, true},
	}
	for _, tc := range cases {
		rec := tc.rec
		if got := p.alwaysRecord(&rec); got != tc.want {
			t.Errorf("%s: alwaysRecord=%v want %v", tc.name, got, tc.want)
		}
	}
}

// newRequestID returns a short, URL-safe request identifier. We avoid
// uuid here because request_id is hot-path and we don't need the entropy
// of a UUID — 12 base32 chars (~60 bits) is plenty to distinguish
// concurrent requests for trace correlation.
func newRequestID() string {
	const alphabet = "0123456789abcdefghijklmnopqrstuv"
	var b [12]byte
	if _, err := rand.Read(b[:]); err != nil {
		// Fall back to a time-based id; collision risk is negligible for
		// log-correlation purposes.
		t := time.Now().UnixNano()
		return strconv.FormatInt(t, 36)
	}
	for i := range b {
		b[i] = alphabet[int(b[i])&31]
	}
	return string(b[:])
}
