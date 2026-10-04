package firstcontent_test

import (
	"encoding/json"
	"math"
	"os"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry/firstcontent"
)

// Swift runs this same fixture through the actual SDK admission predictor.
// These are arithmetic contracts, not measurements or reviewed profiles.
func TestSharedProviderDeadlineDecisions(t *testing.T) {
	data, err := os.ReadFile("../../protocol/testdata/calibrated_deadline_decisions.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Calibration production.Calibration `json:"calibration"`
		Cases       []struct {
			Name             string  `json:"name"`
			Prompt           int     `json:"prompt_tokens"`
			Computed         int     `json:"target_computed_tokens"`
			Output           int     `json:"max_output_tokens"`
			SchedulerPrefill int     `json:"scheduler_prefill_tokens"`
			SchedulerDecode  int     `json:"scheduler_decode_tokens"`
			Context          int     `json:"existing_context_tokens_max"`
			Requests         int     `json:"same_model_requests"`
			LeasePrefill     int     `json:"same_model_prefill_tokens"`
			LeaseDecode      int     `json:"same_model_decode_tokens"`
			PrefillTPS       float64 `json:"observed_prefill_tps"`
			DecodeTPS        float64 `json:"observed_decode_tps"`
			Cache            string  `json:"cache_state"`
			ExpectedMS       float64 `json:"expected_bound_ms"`
			RemainingMS      float64 `json:"remaining_ms"`
			Qualified        bool    `json:"qualified"`
			Admitted         bool    `json:"admitted"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if !fixture.Calibration.Valid(262144) || len(fixture.Cases) < 6 {
		t.Fatal("incomplete shared fixture")
	}
	for _, c := range fixture.Cases {
		t.Run(c.Name, func(t *testing.T) {
			contention := "isolated"
			if c.Requests > 1 {
				contention = "same_model"
			}
			prediction, qualified := fixture.Calibration.Predict(production.Work{
				PromptTokens: c.Prompt, ContextTokens: max(c.Prompt+min(c.Output, 33), c.Context),
				CacheState: c.Cache, Contention: contention, ActiveRequests: c.Requests,
				PrefillTokens:      float64(max(c.SchedulerPrefill, c.LeasePrefill+c.Prompt-c.Computed)),
				DecodeTokens:       float64(max(c.SchedulerDecode, c.LeaseDecode) + min(c.Output, 33)),
				ObservedPrefillTPS: c.PrefillTPS, ObservedDecodeTPS: c.DecodeTPS,
			})
			if qualified != c.Qualified {
				t.Fatalf("qualified=%v, want %v", qualified, c.Qualified)
			}
			if qualified && math.Abs(prediction.ConservativeMS-c.ExpectedMS) > 1e-8 {
				t.Fatalf("bound=%v, want %v", prediction.ConservativeMS, c.ExpectedMS)
			}
			if admitted := qualified && prediction.ConservativeMS <= c.RemainingMS; admitted != c.Admitted {
				t.Fatalf("admitted=%v, want %v", admitted, c.Admitted)
			}
		})
	}
}
