package promptwork

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func exactWork() *protocol.PromptWork {
	return Exact(promptcontract.Plan{Participating: true, PromptContractID: strings.Repeat("b", 64), PromptTokenCount: 4096}, strings.Repeat("a", 64))
}

func TestMemoSeparatesModelsAndFullBodiesAndFreezesProvenance(t *testing.T) {
	var memo Memo
	calls := 0
	plan := func() Result { calls++; return Result{Work: exactWork()} }
	body := []byte(`{"messages":[{"role":"assistant","content":"history"}],"tools":[{"name":"lookup"}]}`)
	first := memo.Plan("qwen", body, plan)
	first.Work.PromptTokens = 1
	if got := memo.Plan("qwen", append([]byte(nil), body...), plan); calls != 1 || got.Work.PromptTokens != 4096 {
		t.Fatal("lost request-local immutable evidence")
	}
	ctx := WithMemo(context.Background(), &memo)
	if got := FromContext(ctx, "qwen", body); got == nil || got.PromptTokens != 4096 {
		t.Fatal("attempt lost original prompt accounting")
	}
	changed := append(append([]byte(nil), body...), ' ')
	if FromContext(ctx, "qwen", changed) != nil || FromContext(ctx, "other", body) != nil {
		t.Fatal("body or artifact rewrite reused stale accounting")
	}
	memo.Plan("qwen", changed, plan)
	memo.Plan("other", body, plan)
	if calls != 3 {
		t.Fatalf("calls=%d", calls)
	}
	if FromContext(context.Background(), "qwen", body) != nil {
		t.Fatal("request leaked evidence to another HTTP request")
	}
}

func TestPlanningUsesOriginalDeadlineAndBoundedNoWaitAdmission(t *testing.T) {
	received := time.Now().Add(-2 * time.Second)
	ctx, cancel := PlanningContext(context.Background(), received, 3*time.Second)
	defer cancel()
	deadline, _ := ctx.Deadline()
	if !deadline.Equal(received.Add(3 * time.Second)) {
		t.Fatal("planning reset original clock")
	}
	expired, stop := PlanningContext(context.Background(), received, time.Second)
	defer stop()
	gate := NewGate()
	if _, ok := gate.Acquire(expired, 100); ok {
		t.Fatal("expired planning admitted")
	}
	releases := make([]func(), 0, 16)
	for i := 0; i < 16; i++ {
		release, ok := gate.Acquire(ctx, 100)
		if !ok {
			t.Fatal("unexpected saturation")
		}
		releases = append(releases, release)
	}
	if _, ok := gate.Acquire(ctx, 100); ok {
		t.Fatal("unbounded planning concurrency")
	}
	releases[0]()
	release, ok := gate.Acquire(ctx, 100)
	if !ok {
		t.Fatal("permit not returned")
	}
	release()
	for _, release := range releases[1:] {
		release()
	}
	if _, ok := gate.Acquire(ctx, promptcontract.DefaultMaxRequestBytes+1); ok {
		t.Fatal("oversize admitted before serialization")
	}
}

func TestExactWorkRequiresValidatedContractAndHeuristicNeverQualifies(t *testing.T) {
	work := exactWork()
	if work == nil || !work.IsQualifiedFor(strings.Repeat("a", 64), strings.Repeat("b", 64)) {
		t.Fatal("lost valid exact accounting")
	}
	if Exact(promptcontract.Plan{PromptTokenCount: 100}, strings.Repeat("a", 64)) != nil {
		t.Fatal("unvalidated sidecar result became exact")
	}
	heuristic := Heuristic(8000)
	if heuristic.UpperBoundTokens != 0 || heuristic.IsQualifiedFor(strings.Repeat("a", 64), strings.Repeat("b", 64)) {
		t.Fatal("heuristic gained invented uncertainty bound")
	}
}

func TestUnplannedAttemptRetainsExplicitUnknownUncertainty(t *testing.T) {
	work := ForAttempt(context.Background(), "unsupported", []byte(`{"input":"synthetic"}`), 3000)
	if work == nil || work.Source != protocol.PromptWorkHeuristic || work.PromptTokens != 3000 || work.UpperBoundTokens != 0 {
		t.Fatal("unsupported endpoint lost explicit heuristic provenance")
	}
}
