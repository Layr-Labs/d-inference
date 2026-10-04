package registry_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestWarmPoolAbsentLoadReleaseDoesNotWake(t *testing.T) {
	r := newWarmRegistry(t)
	r.ConfigureWarmPool(testWarmPoolConfig())
	r.ClearPendingModelLoad("missing", "missing")
	if len(warmFixtureFor(r).deps.Wakeups) != 0 {
		t.Fatal("unmatched completion created a planning wakeup")
	}
}

func runWarmPoolUntilCleanup(t *testing.T, r *production.Registry) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		warmFixtureFor(r).runtime.Run(ctx)
	}()
	t.Cleanup(func() { cancel(); <-done })
}

func expectWarmPoolLoad(t *testing.T, sent <-chan production.ModelLoadAction, provider, model string) {
	t.Helper()
	select {
	case action := <-sent:
		if action.ProviderID != provider || action.ModelID != model {
			t.Fatalf("load = %s/%s, want %s/%s", action.ProviderID, action.ModelID, provider, model)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("freed global load slot did not wake the controller before its hourly tick")
	}
}

func TestWarmPoolReleasedLoadWakesWaitingModel(t *testing.T) {
	for _, release := range []string{"success", "heartbeat_before_success", "disconnect", "catalog_revoked", "inventory_replaced"} {
		t.Run(release, func(t *testing.T) {
			r := newWarmRegistry(t)
			const loaded, waiting = "loaded-model", "waiting-model"
			p := makeWarmPoolColdProvider(t, r, "loading", loaded, 80, 64, 8)
			next := makeWarmPoolColdProvider(t, r, "next", waiting, 80, 64, 8)
			warmFixtureFor(r).loads.Reserve([]production.ModelLoadAction{{ProviderID: p.ID, ModelID: loaded}}, time.Now())
			cfg := testWarmPoolConfig()
			cfg.Interval, cfg.QueueAgeThreshold, cfg.MaxGlobalPendingLoads = time.Hour, 0, 1
			r.ConfigureWarmPool(cfg)
			if release == "heartbeat_before_success" {
				active := loaded
				if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{
					Status: "idle", WarmModels: []string{loaded}, ActiveModel: &active,
					BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: loaded, State: "idle"}}},
				}) {
					t.Fatal("early completion heartbeat rejected")
				}
			}
			if err := r.Queue().Enqueue(swapTestQueued("waiting", waiting)); err != nil {
				t.Fatal(err)
			}
			r.RecordWarmPoolQueueEnqueued(waiting, 1, 0)
			sent := make(chan production.ModelLoadAction, 8)
			warmFixtureFor(r).sender = func(provider, model string) error {
				sent <- production.ModelLoadAction{ProviderID: provider, ModelID: model}
				return nil
			}
			// Consume the original kick while the one-slot global budget is full.
			// Completion must create a new kick; no earlier trigger remains.
			r.TriggerModelSwaps()
			<-warmFixtureFor(r).deps.Wakeups
			warmFixtureFor(r).runtime.Tick(time.Now())
			if len(sent) != 0 || len(warmFixtureFor(r).deps.Wakeups) != 0 {
				t.Fatal("full global budget sent a load or left a spare wakeup")
			}
			switch release {
			case "success", "heartbeat_before_success":
				r.MarkModelWarm(p.ID, loaded)
				r.ClearPendingModelLoad(p.ID, loaded)
			case "disconnect":
				r.Disconnect(p.ID)
			case "catalog_revoked":
				r.SetModelCatalog([]production.CatalogEntry{{ID: waiting}})
				if r.ClearIneligiblePendingModelLoads(p.ID) != 1 {
					t.Fatal("revoked load was not removed")
				}
			case "inventory_replaced":
				generation := r.CommitProviderDrain(p, "drain")
				if !r.CompleteProviderDrain(p, "drain", generation) {
					t.Fatal("provider did not drain")
				}
				if _, _, _, err := r.ReplaceProviderModels(p, &protocol.ModelsReplaceMessage{
					RequestID: "replace", DrainRequestID: "drain",
					Models: []protocol.ModelInfo{{ID: loaded, WeightHash: "new-artifact"}},
				}); err != nil {
					t.Fatal(err)
				}
			}
			runWarmPoolUntilCleanup(t, r)
			expectWarmPoolLoad(t, sent, next.ID, waiting)
		})
	}
}

func TestWarmPoolFailedSendFreesBudgetWithoutRetrySpin(t *testing.T) {
	r := newWarmRegistry(t)
	failed := makeWarmPoolColdProvider(t, r, "failed", "a", 80, 64, 8)
	next := makeWarmPoolColdProvider(t, r, "next", "b", 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.Interval, cfg.QueueAgeThreshold, cfg.MaxGlobalPendingLoads = time.Hour, 0, 1
	r.ConfigureWarmPool(cfg)
	for _, model := range []string{"a", "b"} {
		if err := r.Queue().Enqueue(swapTestQueued(model, model)); err != nil {
			t.Fatal(err)
		}
		r.RecordWarmPoolQueueEnqueued(model, 1, 0)
	}
	sent := make(chan production.ModelLoadAction, 8)
	warmFixtureFor(r).sender = func(provider, model string) error {
		select {
		case sent <- production.ModelLoadAction{ProviderID: provider, ModelID: model}:
		default: // A broken retry loop must not hang test cleanup on the recorder.
		}
		if provider == failed.ID {
			return errors.New("writer stopped before disconnect")
		}
		return nil
	}
	warmFixtureFor(r).runtime.Tick(time.Now())
	expectWarmPoolLoad(t, sent, failed.ID, "a")
	if r.HasPendingModelLoad(failed.ID, "a") || len(warmFixtureFor(r).deps.Wakeups) != 1 {
		t.Fatal("failed send did not release and signal its global load slot")
	}
	// Run the real event loop. Re-selecting the failed provider would either
	// starve b or fill the channel in an unbounded self-triggered retry loop.
	runWarmPoolUntilCleanup(t, r)
	expectWarmPoolLoad(t, sent, next.ID, "b")
	r.MarkModelWarm(next.ID, "b")
	r.ClearPendingModelLoad(next.ID, "b")
	// The lock also waits until the event tick has finished its send path.
	warmFixtureFor(r).runtime.Tick(time.Now())
	if len(sent) != 0 {
		t.Fatal("load planner retried a failed writer during backoff")
	}
	if got := warmFixtureFor(r).loads.Reserve([]production.ModelLoadAction{{ProviderID: failed.ID, ModelID: "a"}}, time.Now()); len(got) != 0 {
		t.Fatal("legacy reservation bypassed proactive send backoff")
	}
	legacyEligible := len(warmFixtureFor(r).loads.Plan([]string{"a"}, time.Now())) != 0
	retryAt := warmFixtureFor(r).lifecycle(failed.ID).retryDeadline()
	reason := warmCandidateReason(r, "a", retryAt)
	if legacyEligible {
		t.Fatal("legacy planner bypassed proactive send backoff")
	}
	if reason != warmplan.WarmColdEligible {
		t.Fatalf("send backoff did not expire: %s", reason)
	}
}

func TestWarmPoolFailedSendCannotOwnReplacementLoad(t *testing.T) {
	for _, replaceSession := range []bool{false, true} {
		for _, beforeSend := range []bool{false, true} {
			name := "new_reservation"
			if replaceSession {
				name = "new_session"
			}
			if beforeSend {
				name += "_before_send"
			} else {
				name += "_during_send"
			}
			t.Run(name, func(t *testing.T) {
				r := newWarmRegistry(t)
				current := makeWarmPoolColdProvider(t, r, "p", "m", 80, 64, 8)
				r.ConfigureWarmPool(testWarmPoolConfig())
				now := time.Now()
				actions := warmFixtureFor(r).loads.Reserve([]production.ModelLoadAction{{ProviderID: "p", ModelID: "m"}}, now)
				replace := func() {
					if replaceSession {
						r.Disconnect("p")
						current = makeWarmPoolColdProvider(t, r, "p", "m", 80, 64, 8)
					} else {
						r.ClearPendingModelLoad("p", "m")
					}
					if got := warmFixtureFor(r).loads.Reserve([]production.ModelLoadAction{{ProviderID: "p", ModelID: "m"}}, now.Add(time.Millisecond)); len(got) != 1 {
						t.Fatal("replacement reservation failed")
					}
					<-warmFixtureFor(r).deps.Wakeups // Account for the genuine old reservation release.
				}
				calls := 0
				warmFixtureFor(r).sender = func(string, string) error {
					calls++
					if !beforeSend {
						replace()
					}
					return errors.New("late writer error")
				}
				if beforeSend {
					replace()
				}
				warmFixtureFor(r).loads.Send(actions)
				wantCalls := 1
				if beforeSend {
					wantCalls = 0
				}
				if calls != wantCalls || !r.HasPendingModelLoad("p", "m") || !warmFixtureFor(r).lifecycle(current.ID).retryDeadline().IsZero() || len(warmFixtureFor(r).deps.Wakeups) != 0 {
					t.Fatalf("stale send affected replacement: calls=%d pending=%t retry=%v triggers=%d", calls, r.HasPendingModelLoad("p", "m"), warmFixtureFor(r).lifecycle(current.ID).retryDeadline(), len(warmFixtureFor(r).deps.Wakeups))
				}
			})
		}
	}
}

func TestWarmPoolExpiredLoadUsableInSamePass(t *testing.T) {
	r := newWarmRegistry(t)
	p := makeWarmPoolColdProvider(t, r, "p", "m", 80, 64, 8)
	warmFixtureFor(r).loads.Reserve([]production.ModelLoadAction{{ProviderID: p.ID, ModelID: "m"}}, time.Now().Add(-2*time.Minute-time.Second))
	cfg := testWarmPoolConfig()
	cfg.MinWarmByModel, cfg.MaxGlobalPendingLoads = map[string]int{"m": 1}, 1
	r.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(r)
	warmFixtureFor(r).runtime.Tick(time.Now())
	if len(*sent) != 1 || (*sent)[0].ProviderID != p.ID {
		t.Fatal("expired reservation required a second planning tick")
	}
}
