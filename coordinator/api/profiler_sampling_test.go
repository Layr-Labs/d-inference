package api

// #809 profiler sink: the sampling decision is taken on the live profile
// BEFORE the row is flattened, with the same predicates the flattened
// alwaysRecord applies (parity pinned below).

import (
	"bytes"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// cleanSuccessProfile is a fully-stamped, decision-carrying clean success —
// the ~90% case that sampling discards at the default rate.
func cleanSuccessProfile(coordID string) (*registry.RequestProfile, *registry.AttemptProfile) {
	return profileFixture(coordID, finalStatusSuccess, "completed")
}

// profileFixture builds a fully-stamped attempt with the given classifier
// status and provider outcome (SetOutcome is first-write-wins, so each case
// must choose its outcome up front).
func profileFixture(coordID, finalStatus, providerOutcome string) (*registry.RequestProfile, *registry.AttemptProfile) {
	rp := registry.NewRequestProfile(time.Now().Add(-time.Second), coordID, nil, 0)
	rp.Model = "m"
	rp.Stamp(&rp.HandlerEntryUS)
	rp.Stamp(&rp.ParsedUS)
	ap := rp.NewAttempt("req-"+newRequestID(), 0, "")
	ap.ProviderID = "prov"
	ap.Mark(registry.StampAttemptStart)
	ap.Mark(registry.StampReserveDone)
	ap.Mark(registry.StampWriteDone)
	ap.Mark(registry.StampFirstContent)
	ap.SetDecision(registry.RoutingDecision{
		ProviderID: "prov", TTFTMs: 900, RawTTFTMs: 1000, CandidateSetSize: 3, NearTiePoolSize: 2,
		RunnerUp: registry.CandidateSummary{Present: true, ProviderID: "prov-2", CostMs: 1234},
		Top:      [4]registry.CandidateSummary{{Present: true, ProviderID: "prov", CostMs: 1000}},
	})
	ap.SetOutcome(finalStatus, "", "", providerOutcome, "")
	return rp, ap
}

type samplingCase struct {
	name   string
	build  func(t *testing.T) (*registry.RequestProfile, *registry.AttemptProfile)
	always bool
}

// clean returns a builder that applies mutate to a clean success.
func clean(mutate func(t *testing.T, rp *registry.RequestProfile, ap *registry.AttemptProfile)) func(t *testing.T) (*registry.RequestProfile, *registry.AttemptProfile) {
	return func(t *testing.T) (*registry.RequestProfile, *registry.AttemptProfile) {
		rp, ap := cleanSuccessProfile("coord-" + newRequestID())
		mutate(t, rp, ap)
		return rp, ap
	}
}

func samplingCorpus(t *testing.T) []samplingCase {
	t.Helper()
	return []samplingCase{
		{"clean success", clean(func(*testing.T, *registry.RequestProfile, *registry.AttemptProfile) {}), false},
		{"valid provider profile on a clean success", clean(func(t *testing.T, rp *registry.RequestProfile, ap *registry.AttemptProfile) {
			// The wire fixture is range-valid only against its own ingress
			// instant (see TestDecodeInferenceProfileFixtureIsValidAndLossless).
			rp.T0 = fixtureReceivedAt
			ap.SetProviderProfileRaw(fixtureProfile(t, "inference_complete_full"))
		}), false},
		{"error", func(*testing.T) (*registry.RequestProfile, *registry.AttemptProfile) {
			return profileFixture("coord-"+newRequestID(), "error", "error")
		}, true},
		{"derived status from a provider error terminal", func(*testing.T) (*registry.RequestProfile, *registry.AttemptProfile) {
			// No classifier status: buildProfileRecord derives it from the
			// provider terminal.
			return profileFixture("coord-"+newRequestID(), "", "error")
		}, true},
		{"derived success from a completed terminal", func(*testing.T) (*registry.RequestProfile, *registry.AttemptProfile) {
			return profileFixture("coord-"+newRequestID(), "", "completed")
		}, false},
		{"slow first content", clean(func(_ *testing.T, _ *registry.RequestProfile, ap *registry.AttemptProfile) {
			ap.FirstContentUS.Store(profileSlowFirstContent.Microseconds() + 1)
		}), true},
		{"slow total", clean(func(_ *testing.T, _ *registry.RequestProfile, ap *registry.AttemptProfile) {
			ap.FinalizedUS.Store(profileSlowTotal.Microseconds() + 1)
		}), true},
		{"retried", clean(func(_ *testing.T, rp *registry.RequestProfile, _ *registry.AttemptProfile) {
			ap2 := rp.NewAttempt("req-"+newRequestID(), 1, "")
			ap2.Mark(registry.StampWriteDone)
		}), true},
		{"backup launched", clean(func(_ *testing.T, _ *registry.RequestProfile, ap *registry.AttemptProfile) {
			ap.BackupLaunched.Store(true)
		}), true},
		{"client gone", clean(func(_ *testing.T, rp *registry.RequestProfile, _ *registry.AttemptProfile) {
			rp.SetClientGonePhase(phaseAfterCommit)
		}), true},
		{"timing anomaly", clean(func(_ *testing.T, _ *registry.RequestProfile, ap *registry.AttemptProfile) {
			ap.WriteDoneUS.Store(10)
			ap.AttemptStartUS.Store(20)
		}), true},
		{"invalid provider profile", clean(func(_ *testing.T, _ *registry.RequestProfile, ap *registry.AttemptProfile) {
			ap.SetProviderProfileRaw([]byte(`{"schema":`))
		}), true},
		{"oversized provider profile (dropped at ingress)", clean(func(t *testing.T, _ *registry.RequestProfile, ap *registry.AttemptProfile) {
			if got := ap.SetProviderProfileRaw(bytes.Repeat([]byte("x"), 4097)); got != registry.ProviderProfileTooLarge {
				t.Fatalf("SetProviderProfileRaw(4097 B) = %v, want ProviderProfileTooLarge", got)
			}
		}), true},
		{"duplicate provider profile after a valid one", clean(func(t *testing.T, rp *registry.RequestProfile, ap *registry.AttemptProfile) {
			// First profile wins and is valid; the duplicate is counted at
			// ingress only, so the attempt is NOT force-recorded on either side.
			rp.T0 = fixtureReceivedAt
			raw := fixtureProfile(t, "inference_complete_full")
			if got := ap.SetProviderProfileRaw(raw); got != registry.ProviderProfileStored {
				t.Fatalf("first SetProviderProfileRaw = %v, want stored", got)
			}
			if got := ap.SetProviderProfileRaw(raw); got != registry.ProviderProfileDuplicate {
				t.Fatalf("second SetProviderProfileRaw = %v, want ProviderProfileDuplicate", got)
			}
		}), false},
		{"late provider profile (after finalization)", clean(func(t *testing.T, rp *registry.RequestProfile, ap *registry.AttemptProfile) {
			rp.T0 = fixtureReceivedAt
			ap.CompleteHandler()
			ap.CompleteTerminal()
			if got := ap.SetProviderProfileRaw(fixtureProfile(t, "inference_complete_full")); got != registry.ProviderProfileLate {
				t.Fatalf("SetProviderProfileRaw after finalization = %v, want ProviderProfileLate", got)
			}
		}), true},
	}
}

// TestProfileSinkSamplesBeforeFlattening: with sampling off, a clean
// success (with or without a valid provider profile) is discarded before
// buildProfileRecord runs; every always-record shape is still flattened and
// persisted.
func TestProfileSinkSamplesBeforeFlattening(t *testing.T) {
	srv := newProfilerTestServer(t)
	srv.profiler.sampleRate = 0
	sink := srv.profiler.sink
	var wantBuilt, wantSampledOut, wantRows int64
	for i, tc := range samplingCorpus(t) {
		rp, ap := tc.build(t)
		if !sink.submit(rp, ap) {
			t.Fatalf("%s: submit dropped", tc.name)
		}
		if tc.always {
			wantBuilt++
			wantRows++
		} else {
			wantSampledOut++
		}
		if !waitForCond(5*time.Second, func() bool {
			return sink.built.Load() == wantBuilt && sink.sampledOut.Load() == wantSampledOut
		}) {
			t.Fatalf("case %d %s: built=%d sampledOut=%d, want %d/%d", i, tc.name, sink.built.Load(), sink.sampledOut.Load(), wantBuilt, wantSampledOut)
		}
	}
	if !waitForCond(5*time.Second, func() bool { return int64(len(srv.store.RequestProfilesSince(time.Time{}))) == wantRows }) {
		t.Fatalf("persisted rows = %d, want %d", len(srv.store.RequestProfilesSince(time.Time{})), wantRows)
	}
	if sink.built.Load() != wantRows {
		t.Fatalf("built %d rows for %d persisted", sink.built.Load(), wantRows)
	}
}

// TestAlwaysRecordRawMatchesFlattened pins parity between the pre-flatten
// predicate and the reference alwaysRecord over the flattened row.
func TestAlwaysRecordRawMatchesFlattened(t *testing.T) {
	srv := newProfilerTestServer(t)
	p := srv.profiler
	for _, tc := range samplingCorpus(t) {
		rp, ap := tc.build(t)
		raw := p.alwaysRecordRaw(rp, ap)
		rec := srv.buildProfileRecord(rp, ap)
		flat := p.alwaysRecord(rec)
		if raw != flat {
			t.Fatalf("%s: alwaysRecordRaw=%v but alwaysRecord(flattened)=%v (row: status=%s valid=%v reason=%s anomaly=%v)", tc.name, raw, flat, rec.FinalStatus, rec.ProviderProfileValid, rec.ProviderProfileInvalidReason, rec.TimingAnomaly)
		}
		if raw != tc.always {
			t.Fatalf("%s: alwaysRecordRaw=%v, want %v", tc.name, raw, tc.always)
		}
	}
	// A sampled-in request records regardless of the predicates.
	rp, ap := cleanSuccessProfile("coord-" + newRequestID())
	p.sampleRate = 1
	if !p.shouldRecord(rp, ap) {
		t.Fatal("sampleRate 1 must record a clean success")
	}
	p.sampleRate = 0
	if p.shouldRecord(rp, ap) || p.shouldRecord(nil, ap) || p.shouldRecord(rp, nil) {
		t.Fatal("sampleRate 0 clean success / nil inputs must not record")
	}
}

// BenchmarkProfileSinkBuildSampledOut measures what a sampled-out clean
// success (decision set, valid raw provider profile retained) costs on the
// sink worker: before, the full flatten (two decision marshals + the
// provider-profile decode) ran before the sampling verdict.
func BenchmarkProfileSinkBuildSampledOut(b *testing.B) {
	srv := NewServer(registry.New(quietLogger()), store.NewMemory(store.Config{}), ServerConfig{}, quietLogger())
	defer srv.Close()
	srv.profiler = &profiler{enabled: true, sampleRate: 0, logger: quietLogger()}
	sink := &profileSink{s: srv}
	rp, ap := cleanSuccessProfile("coord-bench")
	rp.T0 = fixtureReceivedAt
	ap.SetProviderProfileRaw(fixtureProfile(&testing.T{}, "inference_complete_full"))
	job := profileJob{rp: rp, ap: ap}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if rec := sink.build(job); rec != nil {
			b.Fatal("sampled-out job produced a record")
		}
	}
}
