package observation

import (
	"context"
	"encoding/json"

	"net/http"
	"net/http/httptest"

	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func TestProfilerSamplingIsDeterministicPerLogicalRequest(t *testing.T) {
	p := &profiler{enabled: true, sampleRate: 0.5}
	a, b := p.sampled("coord-abc"), p.sampled("coord-abc")
	if a != b {
		t.Fatal("sampling must be deterministic on the coordinator-minted id")
	}
	if !(&profiler{sampleRate: 1}).sampled("x") || (&profiler{sampleRate: 0}).sampled("x") {
		t.Fatal("rate 1 keeps everything, rate 0 keeps nothing")
	}
	if !(&profiler{sampleRate: 0}).sampled("") {
		t.Fatal("a missing id is always kept")
	}
	kept := 0
	for i := 0; i < 2000; i++ {
		if (&profiler{sampleRate: 0.1}).sampled(uuid.NewString()) {
			kept++
		}
	}
	if kept < 120 || kept > 300 {
		t.Fatalf("10%% sample kept %d of 2000", kept)
	}
}

func TestProfilerAlwaysRecordPredicates(t *testing.T) {
	p := &profiler{enabled: true, sampleRate: 0}
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

func TestBuildProfileRecordFlattensStampsAndDecision(t *testing.T) {
	srv := newProfilerTestOwner(t)
	t0 := time.Now().Add(-500 * time.Millisecond)
	rp := registry.NewRequestProfile(t0, "coord-1", nil, 0)
	rp.Endpoint = "POST-/v1/chat/completions"
	rp.Stream = true
	rp.Model = "m"
	rp.AuthDoneUS = 120
	rp.Stamp(&rp.HandlerEntryUS)
	rp.Stamp(&rp.ParsedUS)
	ap := rp.NewAttempt("attempt-uuid", 0, "")
	ap.Mark(registry.StampAttemptStart)
	ap.Mark(registry.StampReserveDone)
	ap.ProviderID = "prov-1"
	ap.ProviderVersion = "0.8.13"
	ap.ChipFamily = "M4"
	ap.SetDecision(registry.RoutingDecision{
		ProviderID: "prov-1", TTFTMs: 900, RawTTFTMs: 1000, CandidateSetSize: 3, NearTiePoolSize: 2,
		RunnerUp: registry.CandidateSummary{Present: true, ProviderID: "prov-2", CostMs: 1234},
		Top:      [4]registry.CandidateSummary{{Present: true, ProviderID: "prov-1", CostMs: 1000}},
	})
	ap.Mark(registry.StampWriteDone)
	ap.Mark(registry.StampFirstContent)
	ap.SetOutcome(finalStatusSuccess, "", "", "completed", "")
	ap.Winning.Store(true)

	rec := srv.buildProfileRecord(rp, ap)
	if rec == nil {
		t.Fatal("nil record")
	}
	if rec.CoordRequestID != "coord-1" || rec.RequestID != "attempt-uuid" || !rec.Winning {
		t.Fatalf("identity mismatch: %+v", rec)
	}
	if rec.AuthDoneUS == nil || *rec.AuthDoneUS != 120 {
		t.Fatal("pre-handler stamp not copied")
	}
	if rec.ParsedUS == nil || rec.ReservedUS != nil {
		t.Fatal("unset stamps must be nil, set stamps non-nil")
	}
	if rec.ProviderVersion != "0.8.13" || rec.ChipFamily != "m4" {
		t.Fatalf("provider snapshot not folded: %q %q", rec.ProviderVersion, rec.ChipFamily)
	}
	if rec.RunnerUpProviderID != "prov-2" || rec.RunnerUpCostMs != 1234 || rec.PredictedTTFTMs != 900 || rec.RawTTFTMs != 1000 {
		t.Fatalf("decision context missing: %+v", rec)
	}
	var cands []candidateJSON
	if err := json.Unmarshal(rec.Candidates, &cands); err != nil || len(cands) != 1 || cands[0].ProviderID != "prov-1" {
		t.Fatalf("candidates JSON: %s (%v)", rec.Candidates, err)
	}
	if rec.ProviderProfileValid || rec.ProviderProfileInvalidReason != providerProfileAbsent {
		t.Fatal("no provider profile must be recorded as absent")
	}
	if rec.TimingAnomaly {
		t.Fatal("monotonic stamps must not flag an anomaly")
	}
}

func TestFoldHelpersNeverPassProviderStringsVerbatim(t *testing.T) {
	if foldChipFamily("M3 Max (evil=1)") != "m3" || foldChipFamily("weird") != profileOther {
		t.Fatal("chip family fold")
	}
	if foldProviderVersion("0.8.13") != "0.8.13" || foldProviderVersion("0.8.13-rc.1") != "0.8.13-rc.1" || foldProviderVersion("v0.8; drop") != "invalid" {
		t.Fatal("version fold")
	}
}

func TestCSVCellGuardsFormulaPrefixes(t *testing.T) {
	for _, in := range []string{"=HYPERLINK(1)", "+1", "-1", "@x", "\tx", "\rx"} {
		if got := csvCell(in); got != "'"+in {
			t.Fatalf("csvCell(%q) = %q", in, got)
		}
	}
	if csvCell("plain") != "plain" || csvCell("") != "" {
		t.Fatal("plain cells untouched")
	}
}

func TestProfileSinkBatchesIntoStoreAndAdminEndpointsServeThem(t *testing.T) {
	srv := newProfilerTestOwner(t)
	if !srv.ProfilerEnabled() || srv.profiler.sink == nil {
		t.Fatal("profiler must be on by default with a store")
	}
	for i := 0; i < 100; i++ {
		rp := registry.NewRequestProfile(time.Now(), "coord-"+strconv.Itoa(i), nil, 0)
		rp.Model = "m"
		ap := rp.NewAttempt("req-"+strconv.Itoa(i), 0, "")
		ap.ProviderID = "prov"
		ap.Mark(registry.StampWriteSubmitted)
		ap.SetOutcome("error", "provider_error", "", "error", "")
		if !srv.profiler.sink.submit(rp, ap) {
			t.Fatal("submit dropped with an empty buffer")
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if len(srv.store.RequestProfilesSinceFiltered(time.Time{}, store.RequestProfileFilter{})) == 100 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if n := len(srv.store.RequestProfilesSinceFiltered(time.Time{}, store.RequestProfileFilter{})); n != 100 {
		t.Fatalf("expected 100 persisted profiles, got %d", n)
	}

	ts := httptest.NewServer(profileAdminHandler(srv))
	defer ts.Close()
	get := func(path string) *http.Response {
		req, _ := http.NewRequest(http.MethodGet, ts.URL+path, nil)
		req.Header.Set("Authorization", "Bearer admin-test-key")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}
	resp := get("/v1/admin/profiles?limit=10")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("admin profiles status %d", resp.StatusCode)
	}
	var page struct {
		Count int                          `json:"count"`
		Data  []store.RequestProfileRecord `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&page); err != nil || page.Count != 10 {
		t.Fatalf("admin profiles page: count=%d err=%v", page.Count, err)
	}
	exp := get("/v1/admin/profiles/export?provider=prov")
	defer exp.Body.Close()
	if exp.StatusCode != http.StatusOK || exp.Header.Get("Content-Type") != "application/x-ndjson" {
		t.Fatalf("export status=%d ctype=%q", exp.StatusCode, exp.Header.Get("Content-Type"))
	}
	unauth, _ := http.Get(ts.URL + "/v1/admin/snapshots")
	if unauth.StatusCode == http.StatusOK {
		t.Fatal("admin snapshots must require the admin key")
	}
	unauth.Body.Close()
}

func TestFleetSampleWritesCoordinatorRowAndPruneRuns(t *testing.T) {
	srv := newProfilerTestOwner(t)
	srv.SampleFleetNow()
	rows := srv.store.FleetSnapshotsSince(time.Time{})
	if len(rows) == 0 {
		t.Fatal("fleet sample must write at least the coordinator row")
	}
	found := false
	for _, r := range rows {
		if r.ProviderID == "coordinator" {
			found = true
			if r.Goroutines <= 0 {
				t.Fatal("coordinator row must carry goroutine count")
			}
		}
	}
	if !found {
		t.Fatal("coordinator row missing")
	}
	srv.PruneTelemetryNow(context.Background())
}

func TestBuildProfileRecordDerivesFinalStatusFromTerminal(t *testing.T) {
	srv := newProfilerTestOwner(t)
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	ap := rp.NewAttempt("a", 0, "")
	ap.SetOutcome("", "", "watchdog", "error", "")
	rec := srv.buildProfileRecord(rp, ap)
	if rec.FinalStatus != "error" || rec.TerminalCause != "watchdog" {
		t.Fatalf("derived status: %+v", rec)
	}
	ap2 := rp.NewAttempt("b", 1, "")
	ap2.SetOutcome("", "", "", "completed", "")
	if rec := srv.buildProfileRecord(rp, ap2); rec.FinalStatus != finalStatusSuccess {
		t.Fatalf("completed must derive success, got %q", rec.FinalStatus)
	}
}
