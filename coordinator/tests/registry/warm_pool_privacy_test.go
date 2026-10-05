package registry_test

import (
	"bufio"
	"bytes"
	"encoding/json"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestWarmPoolLogsExcludeMeasuredWorkload(t *testing.T) {
	var logs bytes.Buffer
	r := newWarmRegistry(t, slog.New(slog.NewJSONHandler(&logs, nil)))
	makeSchedulerProvider(t, r, "provider", "m", 80)
	cfg := testWarmPoolConfig()
	cfg.ObserveOnly = true
	r.ConfigureWarmPool(cfg)
	now := time.Now()
	p := new(warmplan.WorkHistory)
	p.Reconcile(warmWorkCapacity("epoch", 1000, 1, 100, 1), now, warmFixtureFor(r).deps.State, map[string]bool{"m": true}, 2*time.Minute)
	p.Reconcile(warmWorkCapacity("epoch", 9000, 9, 900, 9), now.Add(time.Second), warmFixtureFor(r).deps.State, map[string]bool{"m": true}, 2*time.Minute)
	snaps := warmFixtureFor(r).runtime.Tick(now.Add(time.Second))
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

func TestWarmPoolLoadCommandMetadataStaysOffJSON(t *testing.T) {
	data, err := json.Marshal([]production.ModelLoadAction{{ProviderID: "private-provider", ModelID: "private-model"}})
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "[{}]" {
		t.Fatalf("load command metadata reached snapshot JSON: %s", data)
	}
}
