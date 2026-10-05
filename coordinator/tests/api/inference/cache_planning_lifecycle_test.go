package inference_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCachePlanningActualPendingFailedArtifactAndRecovery(t *testing.T) {
	s := newCachePlanningOwner(t)
	entered, release := make(chan struct{}, 1), make(chan struct{})
	var releaseOnce sync.Once
	var succeed atomic.Bool
	f := newCachePlanningUDSFixtureWithOptions(t, s.Owner, s.registry, cachePlanningFixtureOptions{
		deferReadiness: true,
		artifactHandler: func(w http.ResponseWriter, r *http.Request, payload []byte) {
			select {
			case entered <- struct{}{}:
			default:
			}
			select {
			case <-release:
			case <-r.Context().Done():
				return
			}
			if !succeed.Load() {
				http.Error(w, "synthetic artifact failure", http.StatusServiceUnavailable)
				return
			}
			_, _ = w.Write(payload)
		},
	})
	// Release before fixture teardown; the origin also obeys request cancellation
	// if setup fails before this cleanup can be registered.
	t.Cleanup(func() { releaseOnce.Do(func() { close(release) }) })
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("actual provisioning never reached owned artifact origin")
	}
	if err := s.registry.ConfigureCacheRouting(registry.CacheRoutingConfig{Mode: registry.CacheRoutingOff, ActivationPct: 100}); err != nil {
		t.Fatal(err)
	}
	input := f.input()
	input.HasMedia = true // Artifact prerequisite must still precede media/off.
	status, exists := f.provisioner.Status(f.model)
	if !exists || status.ArtifactReady || status.LastError != "" {
		t.Fatalf("barrier did not retain real pending status: %+v", status)
	}
	s.NewCachePlanner().PlanResult(context.Background(), input)
	releaseOnce.Do(func() { close(release) })
	awaitCondition(t, 3*time.Second, func() bool {
		status, exists := f.provisioner.Status(f.model)
		return exists && !status.ArtifactReady && status.LastError != ""
	}, "origin failure did not reach actual provisioner status")
	s.NewCachePlanner().PlanResult(context.Background(), input)
	snapshot := s.observation.Metrics().Snapshot()
	for _, reason := range []string{"artifact_pending", "artifact_failed"} {
		if snapshot.Counters["exact_cache_planning_decision_total{reason="+reason+"}"] != 1 {
			t.Fatalf("missing real prerequisite decision %s", reason)
		}
	}
	for name, count := range snapshot.Counters {
		if strings.HasPrefix(name, "exact_cache_plan_total{") && count != 0 {
			t.Fatal("artifact prerequisite unexpectedly reached Registry planning")
		}
	}
	succeed.Store(true)
	if err := f.provisioner.Reconcile([]promptcontract.Manifest{f.manifest}); err != nil {
		t.Fatal(err)
	}
	f.waitReady(t)
	if state := f.state(t); state.Plans != 0 {
		t.Fatal("pending/failed prerequisites submitted sidecar work")
	}
	configureCachePreparationTest(t, s.registry)
	if s.NewCachePlanner().PlanResult(context.Background(), f.input()).Plan.CacheScope == "" {
		t.Fatal("actual verified provisioning and preload did not recover")
	}
}

func cachePlanningEndpointBody(model, endpoint string, stream bool) string {
	fields := `"messages":[{"role":"user","content":"planning lifecycle fixture"}],"max_tokens":64`
	if endpoint == "/v1/responses" {
		fields = `"input":"planning lifecycle fixture","max_output_tokens":64`
	} else if endpoint == "/v1/completions" {
		fields = `"prompt":"planning lifecycle fixture","max_tokens":64`
	}
	return fmt.Sprintf(`{"model":%q,%s,"stream":%t}`, model, fields, stream)
}

func assertCachePlanningOnce(t *testing.T, s *serverFixture, f *cachePlanningUDSFixture, before observation.MetricsSnapshot, plansBefore int) {
	t.Helper()
	after := s.observation.Metrics().Snapshot()
	var decisions, legacy int64
	for name, count := range after.Counters {
		if strings.HasPrefix(name, "exact_cache_planning_decision_total{") {
			decisions += count - before.Counters[name]
		}
		if strings.HasPrefix(name, "exact_cache_plan_total{") {
			legacy += count - before.Counters[name]
		}
	}
	if decisions != 1 || legacy != 1 {
		t.Fatalf("logical request replanned: decisions=%d Registry results=%d", decisions, legacy)
	}
	for _, name := range []string{
		"exact_cache_planning_decision_total{reason=planned}",
		"exact_cache_plan_total{outcome=planned}",
		"cache_model_planning_decision_total{model=" + f.model + ",reason=planned}",
		"cache_model_planning_decision_latency_samples_total{model=" + f.model + ",reason=planned}",
	} {
		if after.Counters[name]-before.Counters[name] != 1 {
			t.Errorf("planning count/sample mismatch: %s", name)
		}
	}
	state := f.state(t)
	if state.Plans != plansBefore+1 || state.Active != 0 {
		t.Fatalf("logical request did not finish exactly one actual UDS plan: %+v", state)
	}
}

func TestCachePlanningRetryAndHedgeUseOneDecision(t *testing.T) {
	for _, hedge := range []bool{false, true} {
		for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
			t.Run(fmt.Sprintf("hedge=%t/%s", hedge, endpoint), func(t *testing.T) {
				config := TestServerConfig{}
				if hedge {
					// Leave the current speculative gate enough residual budget for a
					// fresh feasible backup after the primary speculation delay.
					config.FirstContentDeadlineBase = 3 * time.Second
				}
				reg, st, s, transport := setupTTFTFailoverServerWithConfig(t, config)
				t.Cleanup(s.Close)
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				defer cancel()
				const model, alias = "planning-fixture", "planning-public-alias"
				var attempts deadlineAttemptRecorder
				var retries dispatchRecorder
				frames := make(chan protocol.InferenceRequestMessage, 8)
				retry := failFirstScript(&retries, model, "error")
				script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
					select {
					case frames <- req:
					case <-ctx.Done():
						return
					}
					order := attempts.capture(t, reg, fp, req)
					if !hedge {
						retry(ctx, fp, req, body)
					} else if order == 1 {
						fp.sendAccepted(ctx, req) // No content/error; keep the reader available.
					} else {
						fp.serveFull(ctx, req, model, markerFor(fp.name))
					}
				}
				providers := make([]*failoverProvider, 0, 2)
				for i := range 2 {
					fp := startFailoverProvider(t, ctx, transport, reg, failoverProviderConfig{
						Name: fmt.Sprintf("planning-attempt-%d", i), Version: "0.8.15", DecodeTPS: float64(200 - i*100),
						Models: []failoverModelSpec{{ID: model}}, Script: script,
					})
					setPrefixCacheProtocol(t, reg, fp, 1)
					providers = append(providers, fp)
				}
				f := newCachePlanningUDSFixture(t, s.Owner, s.registry, providers[0].registryID, providers[1].registryID)
				for i, fp := range providers {
					capability := cacheEligibilityV2Capability(model)
					capability.ModelAggregateHash, capability.PromptContractID = f.aggregate, f.contract
					capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
					capability.CacheEpoch = []string{"11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"}[i]
					if err := reg.UpdatePrefixCacheCapabilities(fp.registryID, 2, []protocol.PrefixCacheV2Capability{capability}); err != nil {
						t.Fatal(err)
					}
				}
				if hedge {
					for _, fp := range providers {
						reportIdleFirstContentEvidence(reg, fp.registryID, model)
					}
				}
				reg.SetModelAliases(map[string]registry.AliasTarget{alias: {Desired: model}})
				before, plans := s.observation.Metrics().Snapshot(), f.state(t).Plans
				status, body, err := postGenericInference(ctx, transport.URL, endpoint, cachePlanningEndpointBody(alias, endpoint, true))
				if err != nil {
					t.Fatal(err)
				}
				got := attempts.snapshot()
				if len(got) != 2 || got[0].provider == got[1].provider || providers[0].dispatchCount()+providers[1].dispatchCount() != 2 {
					t.Fatalf("did not exercise two distinct provider attempts: %+v", got)
				}
				if status != http.StatusOK || cachePlanningResponseText(endpoint, true, body) != markerFor(got[1].provider) {
					t.Fatalf("winner content was not preserved: status=%d body=%s", status, body)
				}
				if err := cachePlanningResponseTerminalError(endpoint, true, body); err != nil {
					t.Fatal(err)
				}
				for _, fp := range providers {
					fields := readRuntimeDefaultsProviderBody(t, fp)
					assertRuntimeDefaultField(t, fields, "model", model, true)
				}
				assertCachePlanningOnce(t, s, f, before, plans)
				state := f.state(t)
				seenNonces, seenRequests := map[string]bool{}, map[string]bool{}
				for range 2 {
					select {
					case frame := <-frames:
						if frame.PrefixCacheProtocol != 2 || frame.CacheScope != state.LastScope || frame.CacheScope == "" ||
							frame.CacheReceiptNonce == "" || seenNonces[frame.CacheReceiptNonce] || seenRequests[frame.RequestID] ||
							frame.CacheReceiptBoundaryMode != protocol.PrefixCacheReadyBoundaryCheckpoint {
							t.Fatal("planning child cleanup or attempt reuse lost current V2 scope/unique nonce binding")
						}
						seenNonces[frame.CacheReceiptNonce], seenRequests[frame.RequestID] = true, true
					case <-time.After(time.Second):
						t.Fatal("encrypted V2 request envelope was not observed")
					}
				}
				outcome := awaitRequestOutcomes(t, st, 1)[0]
				winners, backups, losers := 0, 0, 0
				for _, attempt := range outcome.Attempts {
					if attempt.Winning {
						winners++
					}
					if attempt.BackupOf != "" {
						backups++
					}
					if attempt.RawReason == "speculative_loser" {
						losers++
					}
				}
				if outcome.Termination != "completed" || winners != 1 || len(outcome.Attempts) != 2 || (hedge && (backups != 1 || losers != 1)) || (!hedge && backups != 0) {
					t.Fatalf("retry/hedge distinction or terminal accounting changed: %+v", outcome)
				}
			})
		}
	}
}

func TestCachePlanningQueuedRequestUsesOneDecision(t *testing.T) {
	t.Setenv(envQueueBeforeShed, "true")
	t.Setenv(envColdDispatch, "false")
	t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "false")
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		t.Run(endpoint, func(t *testing.T) {
			reg, _, s, transport := setupTTFTFailoverServer(t)
			t.Cleanup(s.Close)
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			const model = "planning-fixture"
			fp := startFailoverProvider(t, ctx, transport, reg, failoverProviderConfig{
				Name: "planning-queue-provider", Version: "0.8.15", DecodeTPS: 200,
				Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
			})
			setPrefixCacheProtocol(t, reg, fp, 1)
			f := newCachePlanningUDSFixture(t, s.Owner, s.registry, fp.registryID)
			reg.SetDedicatedModels([]string{model})
			provider := reg.GetProvider(fp.registryID)
			capacity := func(used int64) {
				writeAdaptiveHeartbeat(t, ctx, fp.conn, model, &protocol.BackendCapacity{
					TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{{Model: model, State: "running",
						MaxConcurrency: 1, ActiveTokenBudgetUsed: used, ActiveTokenBudgetMax: 1000}},
				})
			}
			capacity(950)
			awaitCondition(t, time.Second, func() bool {
				provider.Mu().Lock()
				defer provider.Mu().Unlock()
				return provider.BackendCapacity != nil && len(provider.BackendCapacity.Slots) == 1 && provider.BackendCapacity.Slots[0].ActiveTokenBudgetUsed == 950
			}, "occupied heartbeat not installed")
			before, plans := s.observation.Metrics().Snapshot(), f.state(t).Plans
			type response struct {
				status int
				body   string
				err    error
			}
			results := make(chan response, 1)
			done := make(chan struct{})
			go func() {
				defer close(done)
				status, body, err := postGenericInference(ctx, transport.URL, endpoint, cachePlanningEndpointBody(model, endpoint, true), "prefer")
				results <- response{status, body, err}
			}()
			defer func() {
				cancel()
				select {
				case <-done:
				case <-time.After(time.Second):
					t.Error("queued HTTP caller did not drain")
				}
			}()
			awaitCondition(t, 2*time.Second, func() bool { return reg.Queue().QueueSize(model) == 1 }, "request did not enter queue")
			if fp.dispatchCount() != 0 {
				t.Fatal("occupied provider received request before queue release")
			}
			assertCachePlanningOnce(t, s, f, before, plans)
			capacity(0)
			select {
			case got := <-results:
				if got.err != nil || got.status != http.StatusOK || cachePlanningResponseText(endpoint, true, got.body) != markerFor(fp.name) {
					t.Fatalf("queued response failed: %+v", got)
				}
				if err := cachePlanningResponseTerminalError(endpoint, true, got.body); err != nil {
					t.Fatal(err)
				}
			case <-ctx.Done():
				t.Fatal("released queued request did not complete")
			}
			awaitCondition(t, time.Second, func() bool { return reg.Queue().QueueSize(model) == 0 && provider.PendingCount() == 0 }, "queued request state did not drain")
			if fp.dispatchCount() != 1 {
				t.Fatal("queued request did not dispatch exactly once")
			}
			assertCachePlanningOnce(t, s, f, before, plans)
		})
	}
}

func TestCachePlanningCapacityAliasKeepsOriginalClockAndFinalBody(t *testing.T) {
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		for _, exempt := range []bool{false, true} {
			for _, stream := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/exempt=%t/stream=%t", endpoint, exempt, stream), func(t *testing.T) {
					config := TestServerConfig{FirstContentDeadlineBase: 200 * time.Millisecond}
					if exempt {
						config.FirstContentSLAAccounts = []string{}
					}
					reg, st, s, transport := setupTTFTFailoverServerWithConfig(t, config)
					t.Cleanup(s.Close)
					ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
					defer cancel()
					// The previous ID deliberately selects an existing longer SLA.
					// Its generated artifact/provider are synthetic, not real weights.
					const alias, desired, previous = "planning-fallback-alias", "planning-desired", "ternary-bonsai-2-27b"
					seedRuntimeDefaultsModel(t, st, desired, map[string]any{"reasoning_parser": "desired-reasoning", "tool_call_parser": "desired-tools"})
					seedRuntimeDefaultsModel(t, st, previous, map[string]any{"reasoning_parser": "previous-reasoning", "tool_call_parser": "previous-tools"})
					s.server.SyncModelCatalog()
					occupied := startFailoverProvider(t, ctx, transport, reg, failoverProviderConfig{
						Name: "planning-occupied", Version: "0.8.15", DecodeTPS: 200,
						Models: []failoverModelSpec{{ID: desired}}, Script: fullServeScript(desired),
					})
					fallback := startFailoverProvider(t, ctx, transport, reg, failoverProviderConfig{
						Name: "planning-fallback", Version: "0.8.15", DecodeTPS: 200,
						Models: []failoverModelSpec{{ID: previous}}, Script: fullServeScript(previous),
					})
					setPrefixCacheProtocol(t, reg, occupied, 1)
					setPrefixCacheProtocol(t, reg, fallback, 1)
					f := newCachePlanningUDSFixtureWithOptions(t, s.Owner, s.registry, cachePlanningFixtureOptions{model: previous}, fallback.registryID)
					reg.UpdateModelWeightHashes(occupied.registryID, map[string]string{desired: testHash})
					reg.SetModelCatalog([]registry.CatalogEntry{{ID: desired, WeightHash: testHash}, {ID: previous, WeightHash: f.aggregate}})
					reg.SetModelAliases(map[string]registry.AliasTarget{alias: {Desired: desired, Previous: previous}})
					writeAdaptiveHeartbeat(t, ctx, occupied.conn, desired, &protocol.BackendCapacity{
						TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{{Model: desired, State: "running",
							MaxConcurrency: 1, ActiveTokenBudgetUsed: 1000, ActiveTokenBudgetMax: 1000}},
					})
					p := reg.GetProvider(occupied.registryID)
					awaitCondition(t, time.Second, func() bool {
						p.Mu().Lock()
						defer p.Mu().Unlock()
						return p.BackendCapacity != nil && len(p.BackendCapacity.Slots) == 1 && p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed == 1000
					}, "desired-model capacity was not occupied")
					if s.FirstContentDeadline(desired, 16) >= 900*time.Millisecond || s.FirstContentDeadline(previous, 16) <= 2*time.Second {
						t.Fatal("fixture no longer distinguishes pinned original from recomputed fallback budget")
					}
					f.setMode(t, "delayed")
					requestBody := cachePlanningEndpointBody(alias, endpoint, stream)
					status, body, err := postGenericInference(ctx, transport.URL, endpoint, requestBody)
					if err != nil {
						t.Fatal(err)
					}
					state := f.waitState(t, func(state cachePlanningHelperState) bool { return state.Active == 0 })
					if state.Plans != 1 || occupied.dispatchCount() != 0 {
						t.Fatal("request did not reach exactly one post-fallback plan")
					}
					var fields map[string]json.RawMessage
					if err := json.Unmarshal(state.LastBody, &fields); err != nil {
						t.Fatal(err)
					}
					assertRuntimeDefaultField(t, fields, "model", previous, true)
					assertRuntimeDefaultField(t, fields, "reasoning_parser", "previous-reasoning", true)
					assertRuntimeDefaultField(t, fields, "tool_call_parser", "previous-tools", true)
					wantBody := forwardOracle(t, requestBody, func(value map[string]any) {
						value["model"] = previous
						value["reasoning_parser"] = "previous-reasoning"
						value["tool_call_parser"] = "previous-tools"
					})
					if endpoint != "/v1/chat/completions" {
						kind := promptcontract.EndpointMessages
						if endpoint == "/v1/responses" {
							kind = promptcontract.EndpointResponses
						} else if endpoint == "/v1/completions" {
							kind = promptcontract.EndpointCompletions
						}
						wantBody, err = promptcontract.LowerProviderBody(kind, wantBody)
						if err != nil {
							t.Fatal(err)
						}
					}
					// Both transport doubles accept opaque bytes, so parity alone
					// cannot prove re-lowering. Bind each cell to the independent
					// expected final-model rewrite and native endpoint lowering.
					assertProviderBytes(t, state.LastBody, wantBody)
					outcome := "sidecar_error"
					if exempt {
						outcome = "planned"
						if status != http.StatusOK || cachePlanningResponseText(endpoint, stream, body) != markerFor(fallback.name) || fallback.dispatchCount() != 1 || state.Canceled != 0 {
							t.Fatalf("exempt fallback inference failed: status=%d state=%+v response=%s", status, state, body)
						}
						if err := cachePlanningResponseTerminalError(endpoint, stream, body); err != nil {
							t.Fatal(err)
						}
						select {
						case dispatched := <-fallback.bodies:
							if !bytes.Equal(dispatched, state.LastBody) {
								t.Fatal("planner and fallback provider did not receive the same final bytes")
							}
						case <-time.After(time.Second):
							t.Fatal("fallback provider body missing")
						}
					} else {
						if status != http.StatusTooManyRequests || fallback.dispatchCount() != 0 || state.Canceled != 1 || f.supervisor.Client().Stats().Timeouts != 1 {
							t.Fatalf("fallback reset the original request budget: status=%d state=%+v", status, state)
						}
						select {
						case <-fallback.bodies:
							t.Fatal("late fallback dispatch after expired planning")
						case <-time.After(100 * time.Millisecond):
						}
					}
					snapshot := s.observation.Metrics().Snapshot()
					if snapshot.Counters["cache_model_planning_decision_total{model="+previous+",reason="+outcome+"}"] != 1 {
						t.Fatal("decision did not use the final bounded model label")
					}
					assertNoAlias := func(name string) {
						if (strings.HasPrefix(name, "cache_model_planning_decision_") || strings.HasPrefix(name, "exact_cache_planning_decision_")) && strings.Contains(name, alias) {
							t.Errorf("caller alias escaped the new planning metric families: %s", name)
						}
					}
					for name := range snapshot.Counters {
						assertNoAlias(name)
					}
					for name := range snapshot.Histograms {
						assertNoAlias(name)
					}
				})
			}
		}
	}
}

func TestCachePlanningUnsupportedLoweringKeepsNativeForwardBody(t *testing.T) {
	for _, stream := range []bool{false, true} {
		t.Run(fmt.Sprintf("stream=%t", stream), func(t *testing.T) {
			reg, _, s, transport := setupTTFTFailoverServer(t)
			t.Cleanup(s.Close)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			const model = "planning-native-forward"
			fp := startFailoverProvider(t, ctx, transport, reg, failoverProviderConfig{
				Name: "planning-native-forward", Version: "0.8.15", DecodeTPS: 200,
				Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
			})
			setPrefixCacheProtocol(t, reg, fp, 1)
			body := fmt.Sprintf(`{"model":%q,"prompt":["first","second"],"max_tokens":16,"stream":%t}`, model, stream)
			if _, err := promptcontract.LowerProviderBody(promptcontract.EndpointCompletions, []byte(body)); err != promptcontract.ErrEndpointBodyUnsupported {
				t.Fatalf("fixture does not require native-forward fallback: %v", err)
			}
			status, response, err := postGenericInference(ctx, transport.URL, "/v1/completions", body)
			if err != nil || status != http.StatusOK || cachePlanningResponseText("/v1/completions", stream, response) != markerFor(fp.name) {
				t.Fatalf("native-forward inference failed: status=%d error=%v response=%s", status, err, response)
			}
			if err := cachePlanningResponseTerminalError("/v1/completions", stream, response); err != nil {
				t.Fatal(err)
			}
			select {
			case dispatched := <-fp.bodies:
				assertProviderBytes(t, dispatched, forwardOracle(t, body, func(value map[string]any) { value["endpoint"] = "/v1/completions" }))
			case <-time.After(time.Second):
				t.Fatal("native-forward provider body missing")
			}
			snapshot := s.observation.Metrics().Snapshot()
			if snapshot.Counters["exact_cache_planning_decision_total{reason=lowering_unsupported}"] != 1 ||
				snapshot.Counters["exact_cache_planning_decision_total{reason=dependencies_unavailable}"] != 0 || fp.dispatchCount() != 1 {
				t.Fatal("native-forward lowering decision or dispatch count changed")
			}
			for name, count := range snapshot.Counters {
				if strings.HasPrefix(name, "exact_cache_plan_total{") && count != 0 {
					t.Fatal("unsupported lowering unexpectedly reached Registry")
				}
			}
		})
	}
}
