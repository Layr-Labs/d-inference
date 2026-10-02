package api

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestPromptWorkPreflightAndWriterRetainCountAndOriginalClock(t *testing.T) {
	work := &protocol.PromptWork{Version: 1, Source: protocol.PromptWorkExact, PromptTokens: 8828, UpperBoundTokens: 8828, ModelArtifactHash: strings.Repeat("a", 64), PromptContractID: strings.Repeat("b", 64)}
	body := []byte(`{"messages":[{"role":"user","content":"synthetic"}],"tools":[{"type":"function"}]}`)
	calls := 0
	memo := &requestCachePlans{body: func(string) ([]byte, error) { return body, nil }, planWork: func(string, []byte) promptwork.Result { calls++; return promptwork.Result{Work: work} }}
	received := time.Now().Add(-time.Second)
	params := inferenceAdmissionParams{receivedAt: received, deadline: 3 * time.Second, estimatedPromptTokens: 6428, requestedMaxTokens: 32768, cachePlanForModel: memo.forModel, promptWorkForModel: memo.workForModel}
	pending := params.firstContentRequest("model", registry.RequestTraits{HasTools: true})
	if calls != 1 || pending.PromptWork.PromptTokens != 8828 || pending.EstimatedPromptTokens != 6428 || pending.RequestedMaxTokens != 32768 {
		t.Fatal("accounting changed physical reservations or repeated planning")
	}
	builder := providerInferenceFrameBuilder("request", "ephemeral", "ciphertext", pending)
	pending.PromptWork.PromptTokens = 1
	encoded, err := builder(received.Add(2 * time.Second))
	if err != nil {
		t.Fatal(err)
	}
	var frame protocol.InferenceRequestMessage
	if err = json.Unmarshal(encoded, &frame); err != nil {
		t.Fatal(err)
	}
	if frame.PromptWork.PromptTokens != 8828 || frame.FirstContentBudgetMS != 1000 {
		t.Fatal("queued writer changed provenance or reset original clock")
	}
	if _, err = builder(received.Add(4 * time.Second)); err == nil {
		t.Fatal("expired request got another dispatch clock")
	}
	if memo.workForModel("model").PromptTokens != 8828 {
		t.Fatal("attempt mutation corrupted retry evidence")
	}
}

func TestPromptWorkPlanningMemoPreservesAudioIneligibility(t *testing.T) {
	bodies := append(audioCacheBodies(), `{"messages":[{"role":"user","content":"plain input_audio word"}]}`)
	for index, body := range bodies {
		var parsed map[string]any
		if err := json.Unmarshal([]byte(body), &parsed); err != nil {
			t.Fatal(err)
		}
		wantMedia := index < len(bodies)-1
		calls := 0
		memo := newRequestPromptWorkPlans(
			func(string) ([]byte, error) { return []byte(body), nil },
			func(_ string, _ []byte, hasMedia bool) promptwork.Result {
				calls++
				if hasMedia != wantMedia {
					t.Fatalf("case %d: audio cache eligibility changed: got %v want %v", index, hasMedia, wantMedia)
				}
				return promptwork.Result{Work: promptwork.Heuristic(37)}
			}, detectMediaRequirement(parsed), parsed)
		_ = memo.forModel("model")
		_ = memo.forBody("model", []byte(body))
		work := memo.workForModel("model")
		if calls != 1 || work == nil || work.PromptTokens != 37 || work.Source != protocol.PromptWorkHeuristic {
			t.Fatalf("case %d: unified planning lost media gating, original heuristic or memoization", index)
		}
	}
}

func TestPromptWorkQuoteCoversCalibratedUpperBoundAcrossRetries(t *testing.T) {
	var memo promptwork.Memo
	body := []byte(`{"messages":[{"role":"user","content":"synthetic"}]}`)
	work := &protocol.PromptWork{Version: 1, Source: protocol.PromptWorkCalibrated, PromptTokens: 8800, UpperBoundTokens: 11000, CalibrationID: "reviewed-test-corpus", ModelArtifactHash: strings.Repeat("a", 64), PromptContractID: strings.Repeat("b", 64)}
	memo.Plan("model", body, func() promptwork.Result { return promptwork.Result{Work: work} })
	r := httptest.NewRequest("POST", "/v1/chat/completions", nil).WithContext(promptwork.WithMemo(context.Background(), &memo))
	d := &dispatchState{r: r, model: "model", rawBody: body, estimatedPromptTokens: 6400}
	if d.firstContentPromptWork() != 11000 {
		t.Fatal("quote omitted measured uncertainty bound")
	}
	d.rawBody = []byte(`{"messages":[]}`)
	if d.firstContentPromptWork() != 6400 {
		t.Fatal("rewritten attempt borrowed unrelated evidence")
	}
}
