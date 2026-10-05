package inference_test

import (
	"errors"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	routeplan "github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestRequestCachePlanRevalidatesBodyAcrossAliasFallback(t *testing.T) {
	current := []byte(`{"model":"desired","messages":[{"role":"user","content":"original"}]}`)
	calls := 0
	m := routeplan.New(
		func(model string) ([]byte, error) {
			if model == "unsupported" {
				return nil, errors.New("unsupported lowering")
			}
			return current, nil
		},
		func(model string, body []byte, _ bool) promptwork.Result {
			calls++
			return promptwork.Result{Cache: registry.CachePlan{PromptTokenCount: len(body)}}
		}, false, nil)
	initial := m.ForModel("desired")
	if got := m.ForBody("desired", append([]byte(nil), current...)); got.PromptTokenCount != initial.PromptTokenCount || calls != 1 {
		t.Fatal("identical preflight and dispatch bodies planned twice")
	}
	_ = m.ForModel("previous")
	if calls != 2 {
		t.Fatal("alias fallback reused another artifact's plan")
	}
	current = []byte(`{"model":"desired","messages":[{"role":"user","content":"rewritten"}],"reasoning":true}`)
	changed := m.ForModel("desired")
	if calls != 3 || changed.PromptTokenCount == initial.PromptTokenCount {
		t.Fatal("body rewrite retained stale exact prompt work")
	}
	if got := m.ForModel("unsupported"); got.PromptTokenCount != 0 || calls != 3 {
		t.Fatal("unsupported endpoint lowering manufactured a cache plan")
	}
}
