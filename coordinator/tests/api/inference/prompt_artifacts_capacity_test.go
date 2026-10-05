package inference_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// Same oracle and public lifecycle on the pre-selection controller and the
// candidate. All nine tokenizers first prove usable in bounded direct Rust
// batches. The intended old-source failure is the controller's over-C refusal,
// not invalid artifacts.
func TestPromptArtifactCapacityRealSidecarAndAuthenticatedNinth(t *testing.T) {
	for _, shared := range []bool{false, true} {
		name := "nine_distinct"
		if shared {
			name = "nine_models_eight_contracts"
		}
		t.Run(name, func(t *testing.T) {
			f := newCapacityActualFixture(t, shared)
			unique := slices.Clone(f.ids)
			slices.Sort(unique)
			unique = slices.Compact(unique)
			want := 9
			if shared {
				want = 8
			}
			if len(unique) != want || len(f.provisioner.Snapshot().ContractIDs) != want {
				t.Fatal("fixture contract geometry differs")
			}
			for offset := 0; offset < len(unique); offset += 8 {
				ids := unique[offset:min(offset+8, len(unique))]
				report, err := f.supervisor.Client().Preload(f.ctx, ids)
				if err != nil || !report.Ready || report.Failed != 0 || report.Warm+report.Cold != len(ids) {
					t.Fatalf("valid tokenizer control failed: %+v %v", report, err)
				}
				for _, id := range ids {
					modelIndex := slices.Index(f.ids, id)
					if modelIndex < 0 || modelIndex >= len(f.models) {
						t.Fatal("direct tokenizer control has no corresponding fixture model")
					}
					body, err := json.Marshal(map[string]any{
						"model":    f.models[modelIndex],
						"messages": []map[string]string{{"role": "user", "content": "hello"}},
					})
					if err != nil {
						t.Fatal(err)
					}
					plan, err := f.supervisor.Client().Plan(f.ctx, promptcontract.PlanInput{PromptContractID: id,
						ScopeID: "synthetic-capacity-control", Endpoint: promptcontract.EndpointChatCompletions,
						Body: body})
					if err != nil || plan.PromptContractID != id || plan.PromptTokenCount == 0 {
						t.Fatalf("real valid plan: %+v %v", plan, err)
					}
				}
			}
			before := f.metrics(t).Metrics.Preloads.Runs
			if !shared {
				if _, err := f.supervisor.Client().Preload(f.ctx, unique); err == nil {
					t.Fatal("unchanged Client nine-ID guard failed")
				}
				if f.metrics(t).Metrics.Preloads.Runs != before {
					t.Fatal("Client over-capacity refusal reached Rust")
				}
				body, _ := json.Marshal(map[string]any{"prompt_contract_ids": unique})
				request, _ := http.NewRequestWithContext(f.ctx, http.MethodPost, "http://fixture/v1/preload", bytes.NewReader(body))
				request.Header.Set("Content-Type", "application/json")
				response, err := f.control.Do(request)
				if err != nil {
					t.Fatal(err)
				}
				_ = response.Body.Close()
				if response.StatusCode != http.StatusBadRequest || f.metrics(t).Metrics.Preloads.Runs != before {
					t.Fatal("unchanged independent Rust nine-ID guard mutated membership")
				}
			}
			f.controller.Start(f.ctx)
			if shared {
				awaitCondition(t, 5*time.Second, func() bool { return f.controller.ReadyFor(f.ids[8]) }, "deduplicated full V did not preload")
			} else {
				awaitCondition(t, 5*time.Second, func() bool { return f.controller.Status().LastError != "" }, "overflow state was not evaluated")
				if f.metrics(t).Metrics.Preloads.Runs != before || f.controller.Status().Ready {
					t.Fatal("no-demand overflow chose an arbitrary catalog prefix/global Rust ready bit")
				}
				for index := 0; index < 8; index++ {
					f.request(t, index)
				}
				// This is the intended baseline red: the pre-selection controller's
				// whole-catalog attempt refuses before HTTP even though all nine
				// controls really loaded.
				if f.controller.Status().Failures > 0 && f.metrics(t).Metrics.Preloads.Runs == before {
					t.Fatal("nine verified valid contracts still collapse to pre-HTTP whole-catalog capacity refusal")
				}
				awaitCondition(t, 5*time.Second, func() bool {
					for index := 0; index < 8; index++ {
						if !f.controller.ReadyFor(f.ids[index]) {
							return false
						}
					}
					return true
				}, "eight authenticated demanded contracts did not become acknowledged")
				if f.controller.ReadyFor(f.ids[8]) {
					t.Fatal("ninth was selected without demand")
				}
				started := time.Now()
				f.request(t, 8) // Cold ordinary response records interest; it does not await residence/reload.
				if time.Since(started) >= 5*time.Second {
					t.Fatal("cold ninth request waited for preload instead of returning ordinary inference")
				}
				awaitCondition(t, 40*time.Second, func() bool { return f.controller.ReadyFor(f.ids[8]) }, "continuously eligible ninth did not recover through bounded replacement")
			}
			plans := f.server.observation.Metrics().Snapshot().Counters["exact_cache_planning_decision_total{reason=planned}"]
			f.request(t, 8)
			if f.server.observation.Metrics().Snapshot().Counters["exact_cache_planning_decision_total{reason=planned}"] != plans+1 {
				t.Fatal("acknowledged ninth did not reach one actual authenticated HTTP planning decision")
			}
			if f.controller.Status().ContractCount > 8 || f.metrics(t).LoadedContracts > 8 ||
				f.provisioner.Snapshot().Counts.Ready != 9 || len(f.provisioner.Snapshot().ContractIDs) != want || f.supervisor.Status().Restarts != 0 {
				t.Fatal("recovery raised capacity, pruned verification or restarted the child")
			}
			f.close(t)
		})
	}
}
