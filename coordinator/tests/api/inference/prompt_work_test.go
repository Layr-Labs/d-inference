package inference_test

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	providerwire "github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	routeplan "github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestPromptWorkPreflightAndWriterRetainCountAndOriginalClock(t *testing.T) {
	work := &protocol.PromptWork{Version: 1, Source: protocol.PromptWorkExact, PromptTokens: 8828, UpperBoundTokens: 8828, ModelArtifactHash: strings.Repeat("a", 64), PromptContractID: strings.Repeat("b", 64)}
	body := []byte(`{"messages":[{"role":"user","content":"synthetic"}],"tools":[{"type":"function"}]}`)
	calls := 0
	memo := routeplan.New(func(string) ([]byte, error) { return body, nil }, func(string, []byte, bool) promptwork.Result { calls++; return promptwork.Result{Work: work} }, false, nil)
	received := time.Now().Add(-time.Second)
	params := firstcontent.Preflight{ReceivedAt: received, Deadline: 3 * time.Second, EstimatedPromptTokens: 6428, RequestedMaxTokens: 32768, CachePlanForModel: memo.ForModel, PromptWorkForModel: memo.WorkForModel, Calibration: estimate.NewContextCalibration()}
	pending := params.Request("model", registry.RequestTraits{HasTools: true})
	if calls != 1 || pending.PromptWork.PromptTokens != 8828 || pending.EstimatedPromptTokens != 6428 || pending.RequestedMaxTokens != 32768 {
		t.Fatal("accounting changed physical reservations or repeated planning")
	}
	builder := providerwire.FrameBuilder("request", "ephemeral", "ciphertext", pending)
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
	if memo.WorkForModel("model").PromptTokens != 8828 {
		t.Fatal("attempt mutation corrupted retry evidence")
	}
}

func TestPromptWorkQuoteCoversCalibratedUpperBoundAcrossRetries(t *testing.T) {
	var memo promptwork.Memo
	body := []byte(`{"messages":[{"role":"user","content":"synthetic"}]}`)
	work := &protocol.PromptWork{Version: 1, Source: protocol.PromptWorkCalibrated, PromptTokens: 8800, UpperBoundTokens: 11000, CalibrationID: "reviewed-test-corpus", ModelArtifactHash: strings.Repeat("a", 64), PromptContractID: strings.Repeat("b", 64)}
	memo.Plan("model", body, func() promptwork.Result { return promptwork.Result{Work: work} })
	r := httptest.NewRequest("POST", "/v1/chat/completions", nil).WithContext(promptwork.WithMemo(context.Background(), &memo))
	forecast := firstcontent.NewForecast(estimate.NewContextCalibration(),

		nil)
	if forecast.PromptWork(r, "model", body, 6400, 0) != 11000 {
		t.Fatal("quote omitted measured uncertainty bound")
	}
	body = []byte(`{"messages":[]}`)
	if forecast.PromptWork(r, "model", body, 6400, 0) != 6400 {
		t.Fatal("rewritten attempt borrowed unrelated evidence")
	}
}
