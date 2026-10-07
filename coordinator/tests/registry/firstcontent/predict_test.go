package firstcontent_test

import (
	"math"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry/firstcontent"
)

// Synthetic arithmetic fixtures are deliberately not a reviewed hardware profile.
func fixture() (*production.Calibration, production.Work) {
	c := &production.Calibration{Version: production.Version, PromptContractID: strings.Repeat("c", 64), Cells: []production.Cell{{
		PromptTokensMin: 1, PromptTokensMax: 16384, ContextTokensMin: 1, ContextTokensMax: 16384,
		CacheState: "cold", Contention: "isolated", PrefillTPS: 800, DecodeTPS: 80,
		MaxPrefillWorkTokens: 16384, MaxDecodeWorkTokens: 33, MaxActiveRequests: 1,
		ErrorRatio: 1.2, ErrorAdditiveMS: 100,
		CalibrationSampleCount: 20, ValidationSampleCount: 100, ValidationCoveredCount: 100,
		TailCoverage: .95, ReportSHA256: strings.Repeat("a", 64),
	}}}
	return c, production.Work{PromptTokens: 8000, ContextTokens: 8000, CacheState: "cold", Contention: "isolated",
		PrefillTokens: 8000, DecodeTokens: 33, ActiveRequests: 1}
}

func TestPredictionUsesMeasuredErrorEnvelope(t *testing.T) {
	c, w := fixture()
	if !c.Valid(32768) {
		t.Fatal("synthetic calibration invalid")
	}
	p, ok := c.Predict(w)
	if !ok || p.ExpectedMS != 10412.5 || p.ConservativeMS != 12595 {
		t.Fatalf("prediction = %+v, %t", p, ok)
	}
	// Slower fresh measurements may only enlarge the reviewed bound.
	w.ObservedPrefillTPS, w.ObservedDecodeTPS = 400, 160
	slower, ok := c.Predict(w)
	if !ok || slower.ExpectedMS != 20412.5 || slower.ConservativeMS <= p.ConservativeMS {
		t.Fatalf("slower live prefill did not bound reviewed rate: %+v", slower)
	}
}

func TestPredictionRefusesUnmeasuredShapes(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*production.Work)
	}{
		{"prompt band", func(w *production.Work) { w.PromptTokens, w.ContextTokens = 16385, 16385 }},
		{"context band", func(w *production.Work) { w.ContextTokens = 32768 }},
		{"cache state", func(w *production.Work) { w.CacheState = "reused" }},
		{"competing row", func(w *production.Work) { w.ActiveRequests = 2 }},
		{"work ahead", func(w *production.Work) { w.PrefillTokens = 20000 }},
		{"decode work", func(w *production.Work) { w.DecodeTokens = 34 }},
		{"invalid work", func(w *production.Work) { w.PrefillTokens = math.NaN() }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, work := fixture()
			tc.change(&work)
			if _, ok := c.Predict(work); ok {
				t.Fatal("unqualified shape predicted")
			}
		})
	}
}

func TestCompetingProfileIdentityAndFrozenServiceEnvelope(t *testing.T) {
	c, w := fixture()
	cell := &c.Cells[0]
	cell.Contention, cell.CompetitorProfileIDs = "other_model", []string{"other-runtime"}
	cell.MaxActiveRequests, cell.MaxOtherModelRequests, cell.MaxOtherModelServiceFraction = 3, 2, .25
	cell.MaxPrefillWorkTokens, cell.MaxDecodeWorkTokens = 32768, 512
	w.Contention, w.CompetitorProfileIDs = cell.Contention, []string{"other-runtime"}
	w.ActiveRequests, w.OtherModelRequests, w.OtherModelServiceFraction = 3, 2, .25
	w.PrefillTokens, w.DecodeTokens = 9000, 300
	if _, ok := c.Predict(w); !ok {
		t.Fatal("measured competing envelope rejected")
	}
	w.OtherModelServiceFraction = .2501
	if _, ok := c.Predict(w); ok {
		t.Fatal("service beyond measured contention admitted")
	}
	w.OtherModelServiceFraction = .25
	w.CompetitorProfileIDs[0] = "another-runtime"
	if _, ok := c.Predict(w); ok {
		t.Fatal("other model borrowed unrelated contention qualification")
	}
}

func TestCalibrationRequiresIndependentTailCoverage(t *testing.T) {
	c, w := fixture()
	c.Cells[0].ValidationCoveredCount = 18
	if c.Valid(32768) {
		t.Fatal("holdout misses exceeded declared coverage")
	}
	if _, ok := c.Predict(w); ok {
		t.Fatal("invalid evidence used by prediction")
	}
	c.Cells[0].ValidationCoveredCount = 100
	c.Cells[0].CalibrationSampleCount = 19
	if c.Valid(32768) {
		t.Fatal("insufficient independent calibration evidence")
	}
}

func TestOverlappingCellsChooseConservativeBound(t *testing.T) {
	c, w := fixture()
	c.Cells = append(c.Cells, c.Cells[0])
	c.Cells[1].ErrorAdditiveMS = 500
	p, ok := c.Predict(w)
	if !ok || p.CellIndex != 1 || p.ConservativeMS != 12995 {
		t.Fatalf("overlap was optimistic: %+v", p)
	}
	c.Cells[0], c.Cells[1] = c.Cells[1], c.Cells[0]
	p, ok = c.Predict(w)
	if !ok || p.ConservativeMS != 12995 {
		t.Fatal("file order changed the conservative bound")
	}
}
