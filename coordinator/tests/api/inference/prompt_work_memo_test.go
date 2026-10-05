package inference_test

import (
	"encoding/json"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	routeplan "github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestPromptWorkPlanningMemoPreservesAudioIneligibility(t *testing.T) {
	bodies := append(audioCacheBodies(), `{"messages":[{"role":"user","content":"plain input_audio word"}]}`)
	for index, body := range bodies {
		var parsed map[string]any
		if err := json.Unmarshal([]byte(body), &parsed); err != nil {
			t.Fatal(err)
		}
		wantMedia := index < len(bodies)-1
		calls := 0
		memo := routeplan.New(
			func(string) ([]byte, error) { return []byte(body), nil },
			func(_ string, _ []byte, hasMedia bool) promptwork.Result {
				calls++
				if hasMedia != wantMedia {
					t.Fatalf("case %d: audio cache eligibility changed: got %v want %v", index, hasMedia, wantMedia)
				}
				return promptwork.Result{Work: promptwork.Heuristic(37)}
			}, inreq.DetectMediaRequirement(parsed), parsed)
		_ = memo.ForModel("model")
		_ = memo.ForBody("model", []byte(body))
		work := memo.WorkForModel("model")
		if calls != 1 || work == nil || work.PromptTokens != 37 || work.Source != protocol.PromptWorkHeuristic {
			t.Fatalf("case %d: unified planning lost media gating, original heuristic or memoization", index)
		}
	}
}
