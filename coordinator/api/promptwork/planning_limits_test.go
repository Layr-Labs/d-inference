package promptwork

import (
	"context"
	"encoding/base64"
	"io"
	"log/slog"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCountOnlyPlannerHonorsCacheActivationDenials(t *testing.T) {
	input := registry.CachePlanInput{Account: "account", Model: "model",
		PromptContractID: strings.Repeat("b", 64), ModelAggregateSHA256: strings.Repeat("a", 64),
		Body: []byte(`{"messages":[{"role":"user","content":"synthetic"}]}`)}
	for _, tc := range []struct {
		name       string
		mode       string
		percent    float64
		consumeQPS bool
		outcome    registry.CachePlanOutcome
		wantCalls  int
	}{
		{"sampled out", registry.CacheRoutingOn, 1, false, registry.CachePlanSampledOut, 0},
		{"throttled", registry.CacheRoutingOn, 100, true, registry.CachePlanThrottled, 0},
		// Routing off disables cache reuse, not independent bounded prompt
		// accounting. Its cache sampling setting does not disable exact counts.
		{"cache off retains count only", registry.CacheRoutingOff, 1, false, registry.CachePlanOff, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
			if err := r.ConfigureCacheRouting(registry.CacheRoutingConfig{
				Mode: tc.mode, ActivationPct: tc.percent, MaxPlanQPS: .001,
				MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef")),
			}); err != nil {
				t.Fatal(err)
			}
			r.SetModelCatalog([]registry.CatalogEntry{{ID: input.Model, WeightHash: input.ModelAggregateSHA256}})
			cacheClient := promptcontract.NewClient(promptcontract.ClientConfig{
				SocketPath: filepath.Join(t.TempDir(), "absent.sock"), RequestTimeout: 20 * time.Millisecond,
			})
			t.Cleanup(cacheClient.Close)
			if tc.consumeQPS {
				if first := r.PlanCacheRouteWithResult(context.Background(), cacheClient, input); !first.SidecarCalled {
					t.Fatal("fixture did not consume the sole activation token")
				}
			}
			calls := 0
			client := tokenizerFunc(func(_ context.Context, got promptcontract.PlanInput) (promptcontract.Plan, error) {
				calls++
				if got.ScopeID != "first-content-accounting" || string(got.Body) != string(input.Body) {
					t.Fatal("count-only request acquired cache scope or changed body")
				}
				return promptcontract.Plan{Participating: true, PromptContractID: input.PromptContractID, PromptTokenCount: 128}, nil
			})
			var memo Memo
			plan := func() Result {
				return Plan(context.Background(), client, input, Heuristic(100), func(ctx context.Context) registry.CachePlanResult {
					got := r.PlanCacheRouteWithResult(ctx, cacheClient, input)
					if got.Outcome != tc.outcome {
						t.Fatalf("activation outcome=%s, want %s", got.Outcome, tc.outcome)
					}
					return got
				})
			}
			got := memo.Plan(input.Model, input.Body, plan)
			memo.Plan(input.Model, input.Body, plan)
			if calls != tc.wantCalls || got.Cache.CacheScope != "" || len(got.Cache.Boundaries) != 0 {
				t.Fatalf("count-only activation/reuse mismatch: calls=%d result=%+v", calls, got)
			}
			if tc.wantCalls == 0 && got.Work.Source != protocol.PromptWorkHeuristic ||
				tc.wantCalls == 1 && (got.Work.Source != protocol.PromptWorkExact || got.Work.PromptTokens != 128) {
				t.Fatalf("unexpected count evidence: %+v", got.Work)
			}
		})
	}
}

func TestSaturatedAccountingMemoRecoversCacheAndCountWithinOriginalDeadline(t *testing.T) {
	ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(500*time.Millisecond))
	defer cancel()
	deadline, _ := ctx.Deadline()
	gate := NewGate()
	var releases []func()
	for range 16 {
		release, ok := gate.Acquire(ctx, 100)
		if !ok {
			t.Fatal("fixture did not saturate accounting gate")
		}
		releases = append(releases, release)
	}
	defer func() {
		for _, release := range releases {
			release()
		}
	}()
	body := []byte(`{"messages":[{"role":"user","content":"synthetic"}]}`)
	want := Result{Cache: registry.CachePlan{CacheScope: "validated-scope", PromptTokenCount: 4096,
		Boundaries: []protocol.PrefixCacheAnchor{{TokenCount: 1024}}}, Work: exactWork()}
	calls := 0
	plan := func() Result {
		return Account(ctx, gate, len(body), Result{Work: Heuristic(100)}, func(got context.Context) Result {
			calls++
			if current, _ := got.Deadline(); !current.Equal(deadline) {
				t.Fatal("retry reset the original planning deadline")
			}
			return want
		})
	}
	var memo Memo
	first := memo.Plan("model", body, plan)
	if calls != 0 || first.Work.Source != protocol.PromptWorkHeuristic || first.Cache.CacheScope != "" || memo.Lookup("model", body) != nil {
		t.Fatal("saturated attempt executed planning or memoized its fallback")
	}
	releases[0]()
	releases = releases[1:]
	recovered := memo.Plan("model", body, plan)
	if calls != 1 || recovered.Work.Source != protocol.PromptWorkExact || recovered.Cache.CacheScope != want.Cache.CacheScope || len(recovered.Cache.Boundaries) != 1 {
		t.Fatalf("retry did not recover validated cache/count result: %+v", recovered)
	}
	memo.Plan("model", body, plan)
	if calls != 1 || memo.Lookup("model", body).PromptTokens != 4096 {
		t.Fatal("completed retry result was not memoized")
	}
}
