package profiler

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestBuildProfileRecordFlattensStampsAndDecision(t *testing.T) {
	srv := Builder{}
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

	rec := srv.Build(rp, ap)
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

func TestBuildProfileRecordDerivesFinalStatusFromTerminal(t *testing.T) {
	srv := Builder{}
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	ap := rp.NewAttempt("a", 0, "")
	ap.SetOutcome("", "", "watchdog", "error", "")
	rec := srv.Build(rp, ap)
	if rec.FinalStatus != "error" || rec.TerminalCause != "watchdog" {
		t.Fatalf("derived status: %+v", rec)
	}
	ap2 := rp.NewAttempt("b", 1, "")
	ap2.SetOutcome("", "", "", "completed", "")
	if rec := srv.Build(rp, ap2); rec.FinalStatus != finalStatusSuccess {
		t.Fatalf("completed must derive success, got %q", rec.FinalStatus)
	}
}
