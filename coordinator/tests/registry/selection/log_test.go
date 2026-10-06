package selection_test

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

func TestLogDecisionDisabledDoesNotProjectOrAllocate(t *testing.T) {
	logger := slog.New(slog.NewJSONHandler(io.Discard, nil))
	calls := 0
	project := func() selection.DecisionLog {
		calls++
		return selection.DecisionLog{}
	}
	allocs := testing.AllocsPerRun(1000, func() { selection.LogDecision(logger, project) })
	selection.LogDecision(nil, project)
	if calls != 0 || allocs != 0 {
		t.Fatalf("disabled logging projected %d times and allocated %g times", calls, allocs)
	}
}

func TestLogDecisionPreservesEveryField(t *testing.T) {
	var output bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&output, &slog.HandlerOptions{Level: slog.LevelDebug}))
	selection.LogDecision(logger, func() selection.DecisionLog {
		return selection.DecisionLog{RequestID: "request", Model: "model", Winner: "provider",
			Breakdown: cachepolicy.ServiceBreakdown{StateMs: 1, QueueMs: 2, PendingMs: 3, BacklogMs: 4,
				ThisReqMs: 5, HealthMs: 6, CacheDiscountMs: 7, Total: 14},
			Path: "unique_min", CacheTier: "ssd", CacheEstimatedTTFTSavedMs: -904,
			EffectiveTPS: 80, EffectiveQueue: 9, Candidates: 10}
	})
	var record map[string]any
	if err := json.Unmarshal(output.Bytes(), &record); err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"request_id": "request", "model": "model", "winner": "provider", "cost_ms": float64(14),
		"state_ms": float64(1), "queue_ms": float64(2), "pending_ms": float64(3), "backlog_ms": float64(4),
		"this_req_ms": float64(5), "health_ms": float64(6), "selection_path": "unique_min", "cache_tier": "ssd",
		"cache_discount_ms": float64(7), "cache_estimated_ttft_saved_ms": float64(-904), "effective_tps": float64(80),
		"effective_queue": float64(9), "candidates": float64(10), "msg": "routing_decision", "level": "DEBUG",
	}
	for key, value := range want {
		if record[key] != value {
			t.Errorf("%s = %v, want %v", key, record[key], value)
		}
	}
	if len(record) != len(want)+1 || record["time"] == nil {
		t.Fatalf("unexpected log fields: %s", output.Bytes())
	}
}
