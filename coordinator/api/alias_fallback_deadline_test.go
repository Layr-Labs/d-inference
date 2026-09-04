package api

// Alias-fallback deadline recompute (T10-11 (1)): the first-content deadline
// was computed for the initially resolved build BEFORE runInferenceAdmission,
// and a capacity/TTFT alias fallback (maybeFallbackAlias) rewrote `model`
// without touching it. Exact bases are keyed by concrete build id — Qwen3-VL
// runs a 4 s base under the ordinary base — so a fallback across builds ran
// the wrong clock by up to the base difference: the dispatch state, the
// queue wait and the provider's first_content_budget_ms all inherited it.

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestAliasCapacityFallbackRecomputesFirstContentDeadline: the alias's
// Desired build is the exact Qwen3-VL id (4 s coordinator base) and is
// saturated; Previous is an ordinary build (5 s test base) served by a real
// WS provider that captures the first_content_budget_ms it was handed. The
// budget must come from Previous's 5 s clock, not Desired's 4 s one.
func TestAliasCapacityFallbackRecomputesFirstContentDeadline(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	srv.challengeInterval = 30 * time.Second
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const (
		alias     = "qwen3-vl-alias"
		prevBuild = "qwen3-vl-previous-build"
	)
	desiredBuild := modelpolicy.Qwen3VL30BA3BInstructModelID
	if srv.FirstContentDeadline(desiredBuild, 0) >= srv.FirstContentDeadline(prevBuild, 0) {
		t.Fatalf("fixture: desired base %v must be shorter than previous base %v", srv.FirstContentDeadline(desiredBuild, 0), srv.FirstContentDeadline(prevBuild, 0))
	}

	// Desired: trusted, SATURATED (0 candidates / >0 capacity rejections), so
	// the preflight takes the capacity alias fallback.
	registerBuildsProvider(srv, "p-desired", desiredBuild)
	pd := reg.GetProvider("p-desired")
	pd.Mu().Lock()
	pd.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 1_000
	pd.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 1_000
	pd.Mu().Unlock()

	budgets := make(chan int64, 4)
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "p-prev", Version: "0.8.10", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: prevBuild}},
		Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
			budgets <- req.FirstContentBudgetMS
			fp.serveFull(ctx, req, prevBuild, markerFor(fp.name))
		},
	})
	reg.SetModelAliases(map[string]registry.AliasTarget{
		alias: {Desired: desiredBuild, Previous: prevBuild},
	})
	if c, rej, _ := reg.QuickCapacityCheck(desiredBuild, 10, 64, registry.RequestTraits{}); c != 0 || rej == 0 {
		t.Fatalf("desired capacity = %d candidates / %d rejections, want 0 / >0 (saturated)", c, rej)
	}

	body := `{"model":"` + alias + `","messages":[{"role":"user","content":"hello"}],"max_tokens":64,"stream":false}`
	status, respBody, err := postChat(ctx, ts.URL, "test-key", body)
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200 via the Previous build; body=%s", status, respBody)
	}
	var budget int64
	select {
	case budget = <-budgets:
	case <-time.After(5 * time.Second):
		t.Fatal("previous provider never received a dispatch")
	}
	// Previous's clock: 5 s base + 1 ms/token slope − the few ms already
	// spent. Desired's stale clock would hand the provider at most ~4 s.
	desiredCeiling := srv.FirstContentDeadline(desiredBuild, estimatePromptTokens(map[string]any{"messages": []any{map[string]any{"role": "user", "content": "hello"}}})).Milliseconds()
	if budget <= desiredCeiling {
		t.Fatalf("first_content_budget_ms handed to Previous = %d, want > %d (Desired's 4 s base): the deadline was not recomputed for the fallback build", budget, desiredCeiling)
	}
	if want := srv.FirstContentDeadline(prevBuild, 0).Milliseconds(); budget > want+100 || budget < want-1500 {
		t.Fatalf("first_content_budget_ms = %d, want within ~1.5 s under Previous's %d ms base", budget, want)
	}
	if !strings.Contains(respBody, "p-prev") {
		t.Fatalf("response did not come from the Previous provider: %s", respBody)
	}
}
