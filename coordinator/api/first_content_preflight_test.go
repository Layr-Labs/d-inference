package api

import (
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestFirstContentPreflightRetainsOriginalClockAndCalibration(t *testing.T) {
	received := time.Now().Add(-2 * time.Second)
	p := inferenceAdmissionParams{
		estimatedPromptTokens: 1000, requestedMaxTokens: 16000,
		deadline: 10 * time.Second, receivedAt: received,
		cachePlanForModel: func(model string) registry.CachePlan {
			return registry.CachePlan{PromptTokenCount: 1536}
		},
	}
	pr := p.firstContentRequest("gpt-oss", registry.RequestTraits{HasTools: true})
	if !pr.FirstContentDeadline.Equal(received.Add(p.deadline)) {
		t.Fatal("preflight reset the original request clock")
	}
	if pr.EstimatedPromptTokens != 1000 || pr.RequestedMaxTokens != 16000 || pr.FirstContentPromptTokens != calibratedContextPromptTokens("gpt-oss", 1000) {
		t.Fatal("advisory prompt calibration changed physical reservation inputs")
	}
	if pr.CachePlan.PromptTokenCount != 1536 || !pr.Traits.HasTools {
		t.Fatal("preflight lost exact plan or request traits")
	}
	if remaining := p.remainingFirstContentBudget(); remaining > 8*time.Second || remaining <= 7*time.Second {
		t.Fatalf("remaining budget=%v, want original clock minus elapsed processing", remaining)
	}
	p.receivedAt = time.Now().Add(-20 * time.Second)
	if p.remainingFirstContentBudget() != time.Nanosecond {
		t.Fatal("expired positive deadline must not become an exempt zero deadline")
	}
	p.deadline = 0
	if !p.firstContentRequest("gpt-oss", registry.RequestTraits{}).FirstContentDeadline.IsZero() || p.remainingFirstContentBudget() != 0 {
		t.Fatal("preflight added a deadline to an exempt request")
	}
}

func TestRequestCachePlanRevalidatesBodyAcrossAliasFallback(t *testing.T) {
	current := []byte(`{"model":"desired","messages":[{"role":"user","content":"original"}]}`)
	calls := 0
	m := &requestCachePlans{
		body: func(model string) ([]byte, error) {
			if model == "unsupported" {
				return nil, errors.New("unsupported lowering")
			}
			return current, nil
		},
		plan: func(model string, body []byte) registry.CachePlan {
			calls++
			return registry.CachePlan{PromptTokenCount: len(body)}
		},
	}
	initial := m.forModel("desired")
	if got := m.forBody("desired", append([]byte(nil), current...)); got.PromptTokenCount != initial.PromptTokenCount || calls != 1 {
		t.Fatal("identical preflight and dispatch bodies planned twice")
	}
	_ = m.forModel("previous")
	if calls != 2 {
		t.Fatal("alias fallback reused another artifact's plan")
	}
	current = []byte(`{"model":"desired","messages":[{"role":"user","content":"rewritten"}],"reasoning":true}`)
	changed := m.forModel("desired")
	if calls != 3 || changed.PromptTokenCount == initial.PromptTokenCount {
		t.Fatal("body rewrite retained stale exact prompt work")
	}
	if got := m.forModel("unsupported"); got.PromptTokenCount != 0 || calls != 3 {
		t.Fatal("unsupported endpoint lowering manufactured a cache plan")
	}
}
