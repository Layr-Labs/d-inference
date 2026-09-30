package promptwork

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type tokenizerFunc func(context.Context, promptcontract.PlanInput) (promptcontract.Plan, error)

func (f tokenizerFunc) Plan(ctx context.Context, input promptcontract.PlanInput) (promptcontract.Plan, error) {
	return f(ctx, input)
}

func TestPlannerSharesExactCountAndNeverRetriesFailedCacheCall(t *testing.T) {
	input := registry.CachePlanInput{Model: "model", PromptContractID: strings.Repeat("b", 64), ModelAggregateSHA256: strings.Repeat("a", 64), Body: []byte(`{"messages":[]}`)}
	for _, called := range []bool{true, false} {
		calls := 0
		client := tokenizerFunc(func(_ context.Context, got promptcontract.PlanInput) (promptcontract.Plan, error) {
			calls++
			if string(got.Body) != string(input.Body) {
				t.Fatal("tokenizer saw another body")
			}
			return promptcontract.Plan{Participating: true, PromptContractID: input.PromptContractID, PromptTokenCount: 128}, nil
		})
		reused := Plan(context.Background(), client, input, Heuristic(100), func(context.Context) registry.CachePlanResult {
			return registry.CachePlanResult{PromptWork: exactWork(), SidecarCalled: called}
		})
		if reused.Work.PromptTokens != 4096 || calls != 0 {
			t.Fatal("replanned a validated count")
		}
		failed := Plan(context.Background(), client, input, Heuristic(100), func(context.Context) registry.CachePlanResult { return registry.CachePlanResult{SidecarCalled: called} })
		if called {
			if calls != 0 || failed.Work.Source != "heuristic" {
				t.Fatal("retried failed cache planner")
			}
		} else {
			if calls != 1 || failed.Work.Source != "exact_contract" || failed.Work.PromptTokens != 128 {
				t.Fatal("cache-disabled request lost exact short-prompt count")
			}
		}
	}
}

func TestPlannerSpendsInheritedDeadlineWithoutExtendingIt(t *testing.T) {
	deadline := time.Now().Add(25 * time.Millisecond)
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	input := registry.CachePlanInput{PromptContractID: strings.Repeat("b", 64), ModelAggregateSHA256: strings.Repeat("a", 64), Body: []byte(`{"messages":[]}`)}
	client := tokenizerFunc(func(ctx context.Context, _ promptcontract.PlanInput) (promptcontract.Plan, error) {
		got, _ := ctx.Deadline()
		if !got.Equal(deadline) {
			t.Fatal("tokenizer replaced upstream deadline")
		}
		<-ctx.Done()
		return promptcontract.Plan{}, ctx.Err()
	})
	result := Plan(ctx, client, input, Heuristic(100), func(context.Context) registry.CachePlanResult { return registry.CachePlanResult{} })
	if !errors.Is(ctx.Err(), context.DeadlineExceeded) || result.Work.Source != "heuristic" {
		t.Fatal("expired planner changed fallback/deadline")
	}
}
