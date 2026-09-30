package registry

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/firstcontent"
)

func TestDeadlineCatalogRequiresCurrentPromoterContract(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*deadlinePerformanceProfile)
	}{
		{"parallel partial prefill", func(p *deadlinePerformanceProfile) { p.MaxConcurrentPartialPrefills = 2 }},
		{"wide parallel partial prefill", func(p *deadlinePerformanceProfile) { p.MaxConcurrentPartialPrefills = 16 }},
		{"unqualified mixed cap", func(p *deadlinePerformanceProfile) { v := 64; p.MixedPrefillTokenCap = &v }},
		{"zero cooldown", func(p *deadlinePerformanceProfile) { v := 0; p.MinimumWholeMacQuiescenceMS = &v }},
		{"short cooldown", func(p *deadlinePerformanceProfile) { v := 19999; p.MinimumWholeMacQuiescenceMS = &v }},
		{"different cooldown", func(p *deadlinePerformanceProfile) { v := 20001; p.MinimumWholeMacQuiescenceMS = &v }},
		{"different stability", func(p *deadlinePerformanceProfile) { v := 5001; p.MinimumNominalStabilityMS = &v }},
		{"work beyond actual width", func(p *deadlinePerformanceProfile) { p.EffectiveMaxConcurrency = 1 }},
		{"unrelated cell receipt", func(p *deadlinePerformanceProfile) {
			p.DeadlineCalibration.Cells[0].ReportSHA256 = strings.Repeat("e", 64)
		}},
		{"prompt beyond cell context", func(p *deadlinePerformanceProfile) { p.DeadlineCalibration.Cells[0].ContextTokensMax-- }},
		{"too many cells", func(p *deadlinePerformanceProfile) {
			p.DeadlineCalibration.Cells = append(make([]firstcontent.Cell, 128), p.DeadlineCalibration.Cells[0])
			for i := range p.DeadlineCalibration.Cells {
				p.DeadlineCalibration.Cells[i] = p.DeadlineCalibration.Cells[128]
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, _, profile, _ := calibratedCandidateFixture(t, time.Now())
			if !profile.valid() {
				t.Fatal("baseline profile invalid")
			}
			tc.mutate(profile)
			data, err := json.Marshal([]*deadlinePerformanceProfile{profile})
			if err != nil {
				t.Fatal(err)
			}
			if profile.valid() || len(decodeDeadlineProfileCatalog(string(data))) != 0 {
				t.Fatal("catalog accepted a record its promoter cannot emit")
			}
		})
	}
}

func TestDeadlineCatalogAcceptsExactPolicyAndSupportedMixedCaps(t *testing.T) {
	_, _, profile, _ := calibratedCandidateFixture(t, time.Now())
	for _, cap := range []int{128, 256, 512} {
		profile.MixedPrefillTokenCap = &cap
		if !profile.valid() {
			t.Fatalf("qualified mixed cap %d rejected", cap)
		}
	}
}
