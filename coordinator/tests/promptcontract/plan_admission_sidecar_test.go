package promptcontract_test

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// Explicit local sidecar/tokenizer assets only; no network, weights or GPU.
// The artifact loader independently validates each contract's file hashes.
func TestPlannerRealSidecarAdmission(t *testing.T) {
	binary, assets := os.Getenv("DARKBLOOM_TEST_PROMPT_SIDECAR"), os.Getenv("DARKBLOOM_TEST_PROMPT_CONTRACTS")
	if binary == "" || assets == "" {
		t.Skip("requires source-bound local sidecar and contract artifacts")
	}
	parent, err := filepath.EvalSymlinks("/tmp")
	if err != nil {
		t.Fatal(err)
	}
	dir, err := os.MkdirTemp(parent, "planner-real-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	s := production.NewSupervisor(production.SupervisorConfig{Enabled: true, BinaryPath: binary,
		SocketPath: filepath.Join(dir, "sidecar.sock"), ArtifactRoot: assets,
		MaxConcurrency: 4, MaxLoadedContracts: 8, MaxTokens: 65536,
		MemoryLimitMiB: 1024, HealthInterval: 100 * time.Millisecond})
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	s.Start(ctx)
	defer s.Close()
	deadline := time.Now().Add(10 * time.Second)
	for s.Client().Health(ctx) != nil {
		if time.Now().After(deadline) {
			t.Fatal("sidecar startup timed out")
		}
		time.Sleep(10 * time.Millisecond)
	}
	models := []string{"ternary-bonsai-2-27b", "qwen3.8-flash-next"}
	contracts, err := admissionFixtureContracts(assets, models)
	if err != nil {
		t.Fatal(err)
	}
	preload, err := s.Client().Preload(ctx, contracts)
	if err != nil || !preload.Ready || preload.Failed != 0 {
		t.Fatalf("preload: %v %+v", err, preload)
	}
	var durations []time.Duration
	for modelIndex, contract := range contracts {
		for _, repeats := range []int{350, 2800, 4000} {
			body, err := json.Marshal(map[string]any{
				"model": models[modelIndex],
				"messages": []map[string]string{
					{"role": "system", "content": "Synthetic service reference: " + strings.Repeat("Service alpha retries three times, logs structured events, and requires human deployment approval. ", repeats)},
					{"role": "user", "content": "Explain the retry policy; do not modify anything."}},
				"reasoning": map[string]bool{"enabled": false}, "max_tokens": 32, "temperature": 0})
			if err != nil {
				t.Fatal(err)
			}
			input := production.PlanInput{PromptContractID: contract, ScopeID: "synthetic-admission", Endpoint: production.EndpointChatCompletions, Body: body}
			want, err := s.Client().Plan(ctx, input)
			if err != nil {
				t.Fatal(err)
			}
			for trial := range 3 {
				start := make(chan struct{})
				type result struct {
					plan    production.Plan
					err     error
					elapsed time.Duration
				}
				done := make(chan result, 40)
				for range 40 {
					go func() {
						<-start
						begin := time.Now()
						plan, err := s.Client().Plan(ctx, input)
						done <- result{plan, err, time.Since(begin)}
					}()
				}
				close(start)
				for range 40 {
					r := <-done
					if r.err != nil || !reflect.DeepEqual(r.plan, want) {
						t.Fatalf("tokens=%d trial=%d: error=%v exact=%t", want.PromptTokenCount, trial, r.err, reflect.DeepEqual(r.plan, want))
					}
					durations = append(durations, r.elapsed)
				}
			}
			t.Logf("contract=%s tokens=%d planned=120/120 exact=true", contract, want.PromptTokenCount)
		}
	}
	// One heterogeneous burst checks short/long prompts, both contracts and
	// independent scopes against separate exact references, not a shared oracle.
	var mixed []production.PlanInput
	var mixedReference []production.Plan
	for modelIndex, contract := range contracts {
		for _, repeats := range []int{2, 4000} {
			for _, scope := range []string{"fixture-tenant-a", "fixture-tenant-b"} {
				body, err := json.Marshal(map[string]any{"model": models[modelIndex],
					"messages":  []map[string]string{{"role": "user", "content": strings.Repeat("Service alpha retries three times. ", repeats)}},
					"reasoning": map[string]bool{"enabled": false}})
				if err != nil {
					t.Fatal(err)
				}
				input := production.PlanInput{PromptContractID: contract, ScopeID: scope, Endpoint: production.EndpointChatCompletions, Body: body}
				plan, err := s.Client().Plan(ctx, input)
				if err != nil {
					t.Fatal(err)
				}
				mixed = append(mixed, input)
				mixedReference = append(mixedReference, plan)
			}
		}
	}
	startMixed, doneMixed := make(chan struct{}), make(chan bool, 40)
	for i := range 40 {
		go func() {
			<-startMixed
			j := i % len(mixed)
			plan, err := s.Client().Plan(ctx, mixed[j])
			doneMixed <- err == nil && reflect.DeepEqual(plan, mixedReference[j])
		}()
	}
	close(startMixed)
	for range 40 {
		if !<-doneMixed {
			t.Fatal("mixed length/tenant burst failed exactness or deadline")
		}
	}
	t.Log("mixed_length_contract_scope_plans=40/40 exact=true")
	if stats := s.Client().Stats(); stats.Overloads != 0 || stats.Timeouts != 0 {
		t.Fatal(stats)
	}
	if s.Status().Restarts != 0 {
		t.Fatal("sidecar restarted")
	}
	sort.Slice(durations, func(i, j int) bool { return durations[i] < durations[j] })
	t.Logf("planned=%d total_p95=%s total_max=%s; planning completion, NOT SSD hits", len(durations), durations[(len(durations)*95+99)/100-1], durations[len(durations)-1])
}
