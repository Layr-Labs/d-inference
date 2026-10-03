package service

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// workerStore adds the Postgres-only maintenance and receipt capabilities to
// the memory store and counts how often each background worker calls them.
type workerStore struct {
	*store.MemoryStore
	mu                      sync.Mutex
	reconciles, queues      int
	claims, inventoryPasses int
	maintenanceErr          error
}

func (s *workerStore) ReconcileAppAttestEvidence(_ context.Context, before time.Time, limit int) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.reconciles++
	if limit != 100 || time.Since(before) < 5*time.Minute {
		return 0, errors.New("unbounded reconciliation")
	}
	return 2, s.maintenanceErr
}

func (s *workerStore) QueueAppAttestReceiptRecovery(_ context.Context, limit int) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.queues++
	return 3, nil
}

func (s *workerStore) ClaimAppAttestReceipt(context.Context, time.Time) (*store.AppAttestReceipt, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.claims++
	return nil, nil
}

func (s *workerStore) SaveAppAttestReceiptRefresh(context.Context, store.AppAttestReceipt) error {
	return errors.New("no receipt was claimed")
}

func (s *workerStore) ReconcileMachineInventory(ctx context.Context, before time.Time, limit int) (int, error) {
	s.mu.Lock()
	s.inventoryPasses++
	s.mu.Unlock()
	return s.MemoryStore.ReconcileMachineInventory(ctx, before, limit)
}

func (s *workerStore) counts() (reconciles, queues, claims, inventory int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.reconciles, s.queues, s.claims, s.inventoryPasses
}

type trustUpdate struct {
	provider *registry.Provider
	status   string
}

func TestStartRunsEveryWorkerUntilServiceContextEnds(t *testing.T) {
	_, keyPath := receiptTestKey(t)
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		logger := slog.New(slog.NewTextHandler(io.Discard, nil))
		r := registry.New(logger)
		st := &workerStore{MemoryStore: store.NewMemory(store.Config{})}
		m := newMetricLog()
		var mu sync.Mutex
		var releaseRefreshes int
		var updates []trustUpdate
		s := New(ctx, Config{Enabled: true, ServingEnabled: true, Environment: "production", AppID: "TEST.app", ReceiptKeyPath: keyPath, ReceiptKeyID: "TESTKEY"}, Dependencies{
			Store: st, Registry: r, Logger: logger, Metrics: m.metrics(),
			RefreshReleasePolicy: func() error { mu.Lock(); releaseRefreshes++; mu.Unlock(); return nil },
			SendTrustStatus: func(p *registry.Provider, _ registry.TrustLevel, status, _ string) {
				mu.Lock()
				updates = append(updates, trustUpdate{p, status})
				mu.Unlock()
			},
		})
		s.Start()
		authorizer := s.authorizer
		s.Start() // A second call must not start a second set of workers.
		synctest.Wait()

		if authorizer == nil || s.authorizer != authorizer {
			t.Fatal("serving authorizer not started exactly once")
		}
		if enabled, _ := r.AppAttestServingPolicy(); !enabled {
			t.Fatal("registry serving policy not enabled")
		}
		if s.qualifications.Load() == nil {
			t.Fatal("build qualifications not loaded at start")
		}
		mu.Lock()
		if releaseRefreshes != 1 {
			t.Fatalf("release policy refreshed %d times at start", releaseRefreshes)
		}
		mu.Unlock()
		if g := m.gauge("app_attest.receipt.configured"); len(g) != 1 || g[0] != 1 {
			t.Fatalf("receipt configured gauge %v", g)
		}
		if reconciles, queues, _, inventory := st.counts(); reconciles != 1 || queues != 1 || inventory != 1 {
			t.Fatalf("first maintenance pass reconciles=%d queues=%d inventory=%d", reconciles, queues, inventory)
		}
		m.mu.Lock()
		interrupted, recovery := m.counts["app_attest.maintenance.interrupted"], m.counts["app_attest.maintenance.receipt_recovery"]
		m.mu.Unlock()
		if len(interrupted) != 1 || interrupted[0] != 2 || len(recovery) != 1 || recovery[0] != 3 {
			t.Fatalf("maintenance counts interrupted=%v recovery=%v", interrupted, recovery)
		}

		// The notification workers deliver queued status changes off the
		// caller's goroutine.
		p := r.Register("provider", nil, &protocol.RegisterMessage{})
		authorizer.forget(p)
		synctest.Wait()
		mu.Lock()
		if len(updates) != 1 || updates[0].provider != p {
			t.Fatalf("status notifications %+v", updates)
		}
		mu.Unlock()
		authorizer.mu.Lock()
		pending := len(authorizer.postPending)
		authorizer.mu.Unlock()
		if pending != 0 {
			t.Fatal("delivered notification still pending")
		}

		// One refresh period later the periodic workers have run again.
		time.Sleep(appAttestAuthorizationRefresh)
		synctest.Wait()
		mu.Lock()
		if releaseRefreshes != 2 {
			t.Fatalf("release policy refreshes after one period: %d", releaseRefreshes)
		}
		mu.Unlock()
		if _, _, claims, inventory := st.counts(); claims != 5 || inventory != 2 {
			t.Fatalf("after 5s claims=%d inventory=%d", claims, inventory)
		}
		time.Sleep(time.Minute)
		synctest.Wait()
		if reconciles, queues, _, _ := st.counts(); reconciles != 2 || queues != 2 {
			t.Fatalf("maintenance did not repeat each minute: %d %d", reconciles, queues)
		}

		// synctest.Test fails if any worker goroutine outlives the context.
		cancel()
		synctest.Wait()
		r.Disconnect(p.ID)
	})
}

func TestStartWithoutOptInsKeepsOnlyUnconditionalWorkers(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		logger := slog.New(slog.NewTextHandler(io.Discard, nil))
		r := registry.New(logger)
		mem := store.NewMemory(store.Config{})
		m := newMetricLog()
		refreshed := false
		s := New(ctx, Config{Environment: "production"}, Dependencies{Store: mem, Registry: r, Logger: logger, Metrics: m.metrics(),
			RefreshReleasePolicy: func() error { refreshed = true; return nil }})
		s.Start()
		synctest.Wait()
		if s.authorizer != nil || s.qualifications.Load() != nil || refreshed {
			t.Fatal("serving workers started without an opt-in")
		}
		if enabled, _ := r.AppAttestServingPolicy(); enabled {
			t.Fatal("registry serving policy enabled without an opt-in")
		}
		if g := m.gauge("app_attest.receipt.configured"); len(g) != 1 || g[0] != 0 {
			t.Fatalf("receipt renewal reported configured without credentials: %v", g)
		}
		cancel()
		synctest.Wait()
	})
}

func TestAuthorizerStartsOnlyForProductionServing(t *testing.T) {
	for _, cfg := range []Config{{ServingEnabled: true, Environment: "development"}, {Environment: "production"}} {
		r := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
		s := &Service{registry: r, logger: slog.New(slog.NewTextHandler(io.Discard, nil)), config: cfg}
		s.startAppAttestAuthorizer(context.Background())
		if enabled, _ := r.AppAttestServingPolicy(); s.authorizer != nil || enabled {
			t.Fatalf("authorizer started for %+v", cfg)
		}
	}
}

func TestMaintenanceFailureIsCountedOnlyWhileRunning(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		st := &workerStore{MemoryStore: store.NewMemory(store.Config{}), maintenanceErr: errors.New("database unavailable")}
		m := newMetricLog()
		s := &Service{store: st, logger: slog.New(slog.NewTextHandler(io.Discard, nil)), metrics: m.metrics()}
		s.startAppAttestMaintenance(ctx)
		synctest.Wait()
		if got := m.incrCount("app_attest.maintenance.failed"); got != 1 {
			t.Fatalf("failure count %d", got)
		}
		if _, queues, _, _ := st.counts(); queues != 0 {
			t.Fatal("receipt recovery queued after reconciliation failed")
		}
		cancel()
		synctest.Wait()
		if got := m.incrCount("app_attest.maintenance.failed"); got != 1 {
			t.Fatalf("shutdown counted as failure: %d", got)
		}
	})
}

func TestBuildQualificationWorkerCountsRefreshFailures(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		m := newMetricLog()
		s := &Service{store: &failingBuildStore{store.NewMemory(store.Config{})}, logger: slog.New(slog.NewTextHandler(io.Discard, nil)), metrics: m.metrics(),
			config: Config{ServingEnabled: true}, refreshReleasePolicy: func() error { return errors.New("catalog unavailable") }}
		s.startBuildQualifications(ctx)
		if m.incrCount("app_attest.qualification.refresh_failed") != 1 || m.incrCount("app_attest.release_refresh_failed") != 1 {
			t.Fatalf("start refresh failures not counted: %v", m.incr)
		}
		time.Sleep(appAttestAuthorizationRefresh)
		synctest.Wait()
		if m.incrCount("app_attest.qualification.refresh_failed") != 2 || m.incrCount("app_attest.release_refresh_failed") != 2 {
			t.Fatalf("periodic refresh failures not counted: %v", m.incr)
		}
		if s.qualifications.Load() != nil {
			t.Fatal("failed refresh published a snapshot")
		}
		cancel()
		synctest.Wait()
	})
}

func TestInventoryReconcilerRepeatsUntilCancelled(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		st := &workerStore{MemoryStore: store.NewMemory(store.Config{})}
		s := &Service{store: st, logger: slog.New(slog.NewTextHandler(io.Discard, nil)), inventorySlots: make(chan struct{}, 4)}
		s.startMachineInventoryReconciler(ctx)
		synctest.Wait()
		time.Sleep(10 * time.Second)
		synctest.Wait()
		if _, _, _, passes := st.counts(); passes != 3 {
			t.Fatalf("reconciler passes %d, want start plus two ticks", passes)
		}
		cancel()
		synctest.Wait()
	})
}
