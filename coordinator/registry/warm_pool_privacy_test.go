package registry

import (
	"bufio"
	"bytes"
	"encoding/json"
	"log/slog"
	"testing"
	"time"
)

func TestWarmPoolLogsExcludeMeasuredWorkload(t *testing.T) {
	var logs bytes.Buffer
	r := New(slog.New(slog.NewJSONHandler(&logs, nil)))
	makeSchedulerProvider(t, r, "provider", "m", 80)
	cfg := testWarmPoolConfig()
	cfg.ObserveOnly = true
	r.ConfigureWarmPool(cfg)
	now := time.Now()
	p := &Provider{}
	p.reconcileWarmPoolWorkLocked(warmWorkCapacity("epoch", 1000, 1, 100, 1), now, r.warmPool, map[string]bool{"m": true})
	p.reconcileWarmPoolWorkLocked(warmWorkCapacity("epoch", 9000, 9, 900, 9), now.Add(time.Second), r.warmPool, map[string]bool{"m": true})
	snaps := r.warmPool.tick(now.Add(time.Second))
	if len(snaps) != 1 || snaps[0].MeasuredPromptTokens != 1000 || snaps[0].MeasuredOutputTokens != 100 {
		t.Fatalf("test must exercise real measured workload: %+v", snaps)
	}
	found := false
	scanner := bufio.NewScanner(&logs)
	for scanner.Scan() {
		var record map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
			t.Fatal(err)
		}
		if record["msg"] != "warm_pool_tick" {
			continue
		}
		found = true
		for _, field := range []string{"measured_prompt_tokens", "measured_output_tokens", "prompt_work_tps", "generation_work_tps"} {
			if _, exists := record[field]; exists {
				t.Errorf("measured workload field reached process logs: %s", field)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("missing warm pool log record")
	}
}
