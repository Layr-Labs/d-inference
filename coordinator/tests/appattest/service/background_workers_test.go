package service_test

import (
	"context"
	"encoding/base64"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

// workerStore adds the Postgres-only maintenance and receipt capabilities to
// the memory store and counts how often each background worker calls them.
type workerStore struct {
	*memorystore.MemoryStore
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

func (s *workerStore) QueueAppAttestReceiptRecovery(context.Context, int) (int64, error) {
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

type failingBuildStore struct{ *memorystore.MemoryStore }

func (*failingBuildStore) ListAppAttestBuildQualifications(context.Context) ([]store.AppAttestBuildQualification, error) {
	return nil, errors.New("unavailable")
}

type trustUpdate struct {
	provider *registry.Provider
	status   string
}

// trustUpdates records SendTrustStatus calls, which notification workers make
// from their own goroutines.
type trustUpdates struct {
	mu      sync.Mutex
	updates []trustUpdate
}

func (u *trustUpdates) send(p *registry.Provider, _ registry.TrustLevel, status, _ string) {
	u.mu.Lock()
	defer u.mu.Unlock()
	u.updates = append(u.updates, trustUpdate{p, status})
}

func (u *trustUpdates) list() []trustUpdate {
	u.mu.Lock()
	defer u.mu.Unlock()
	return append([]trustUpdate(nil), u.updates...)
}

// revokePresenter registers a provider as the verified presenter of a
// credential, then revokes that credential. Only a started serving authorizer
// queues the provider's status change.
func revokePresenter(t *testing.T, r *registry.Registry, s *service.Service) *registry.Provider {
	t.Helper()
	endpoint := base64.StdEncoding.EncodeToString(make([]byte, 32))
	p := r.Register("presenter", nil, &protocol.RegisterMessage{PublicKey: endpoint})
	p.AccountID = "account"
	if current, _ := r.RecordVerifiedAppAttestPresenter(p, "credential", "account", endpoint); !current {
		t.Fatal("presenter not recorded")
	}
	s.RevokeCredential("credential")
	return p
}

func TestStartRunsEveryWorkerUntilServiceContextEnds(t *testing.T) {
	_, keyPath := receiptTestKey(t)
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		logger := discardLogger()
		r := registry.New(logger)
		st := &workerStore{MemoryStore: memorystore.NewMemory(store.Config{})}
		qualified := readinessTestBuild(strings.Repeat("a", 64))
		if _, err := st.QualifyAppAttestBuild(ctx, qualified); err != nil {
			t.Fatal(err)
		}
		m := newMetricLog()
		outbox := authorization.NewOutbox(4)
		trust := &trustUpdates{}
		var releaseRefreshes atomic.Int32
		s := service.New(ctx, service.Config{Enabled: true, ServingEnabled: true, Environment: "production", AppID: "TEST.app", ReceiptKeyPath: keyPath, ReceiptKeyID: "TESTKEY"}, service.Dependencies{
			Store: st, Registry: r, Logger: logger, Metrics: m.metrics(), Notifications: outbox, SendTrustStatus: trust.send,
			RefreshReleasePolicy: func() error { releaseRefreshes.Add(1); return nil },
		})
		s.Start()
		s.Start() // A second call must not start a second set of workers.
		synctest.Wait()

		if enabled, _ := r.AppAttestServingPolicy(); !enabled {
			t.Fatal("registry serving policy not enabled")
		}
		if !s.ReleaseReady(qualified.Release) {
			t.Fatal("build qualifications not loaded at start")
		}
		if got := releaseRefreshes.Load(); got != 1 {
			t.Fatalf("release policy refreshed %d times at start", got)
		}
		if g := m.gauge("app_attest.receipt.configured"); len(g) != 1 || g[0] != 1 {
			t.Fatalf("receipt configured gauge %v", g)
		}
		if reconciles, queues, _, inventory := st.counts(); reconciles != 1 || queues != 1 || inventory != 1 {
			t.Fatalf("first maintenance pass reconciles=%d queues=%d inventory=%d", reconciles, queues, inventory)
		}
		interrupted, recovery := m.count("app_attest.maintenance.interrupted"), m.count("app_attest.maintenance.receipt_recovery")
		if len(interrupted) != 1 || interrupted[0] != 2 || len(recovery) != 1 || recovery[0] != 3 {
			t.Fatalf("maintenance counts interrupted=%v recovery=%v", interrupted, recovery)
		}

		// The started authorizer queues the revoked presenter; the notification
		// workers deliver it off the caller's goroutine.
		p := revokePresenter(t, r, s)
		synctest.Wait()
		if got := trust.list(); len(got) != 1 || got[0].provider != p || got[0].status != string(registry.StatusUntrusted) {
			t.Fatalf("status notifications %+v", got)
		}
		if outbox.Pending() != 0 {
			t.Fatal("delivered notification still pending")
		}

		// One refresh period later the periodic workers have run again.
		time.Sleep(authorization.RefreshInterval)
		synctest.Wait()
		if got := releaseRefreshes.Load(); got != 2 {
			t.Fatalf("release policy refreshes after one period: %d", got)
		}
		if _, _, claims, inventory := st.counts(); claims != 5 || inventory != 2 {
			t.Fatalf("after one refresh period claims=%d inventory=%d", claims, inventory)
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
		logger := discardLogger()
		r := registry.New(logger)
		mem := memorystore.NewMemory(store.Config{})
		qualified := readinessTestBuild(strings.Repeat("a", 64))
		if _, err := mem.QualifyAppAttestBuild(ctx, qualified); err != nil {
			t.Fatal(err)
		}
		m := newMetricLog()
		trust := &trustUpdates{}
		var refreshed atomic.Bool
		s := service.New(ctx, service.Config{Environment: "production"}, service.Dependencies{Store: mem, Registry: r, Logger: logger, Metrics: m.metrics(),
			SendTrustStatus: trust.send, RefreshReleasePolicy: func() error { refreshed.Store(true); return nil }})
		s.Start()
		synctest.Wait()
		if s.ReleaseReady(qualified.Release) || refreshed.Load() {
			t.Fatal("serving workers started without an opt-in")
		}
		if enabled, _ := r.AppAttestServingPolicy(); enabled {
			t.Fatal("registry serving policy enabled without an opt-in")
		}
		p := revokePresenter(t, r, s)
		synctest.Wait()
		if got := trust.list(); len(got) != 0 {
			t.Fatalf("notification delivered without a serving authorizer: %+v", got)
		}
		if g := m.gauge("app_attest.receipt.configured"); len(g) != 1 || g[0] != 0 {
			t.Fatalf("receipt renewal reported configured without credentials: %v", g)
		}
		cancel()
		synctest.Wait()
		r.Disconnect(p.ID)
	})
}

func TestAuthorizerStartsOnlyForProductionServing(t *testing.T) {
	for _, cfg := range []service.Config{{ServingEnabled: true, Environment: "development"}, {Environment: "production"}} {
		synctest.Test(t, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			r := registry.New(discardLogger())
			s := service.New(ctx, cfg, service.Dependencies{Store: memorystore.NewMemory(store.Config{}), Registry: r, Logger: discardLogger()})
			s.Start()
			synctest.Wait()
			if enabled, _ := r.AppAttestServingPolicy(); enabled {
				t.Fatalf("authorizer started for %+v", cfg)
			}
			cancel()
			synctest.Wait()
		})
	}
}

func TestMaintenanceFailureIsCountedOnlyWhileRunning(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		st := &workerStore{MemoryStore: memorystore.NewMemory(store.Config{}), maintenanceErr: errors.New("database unavailable")}
		m := newMetricLog()
		s := service.New(ctx, service.Config{}, service.Dependencies{Store: st, Logger: discardLogger(), Metrics: m.metrics()})
		s.Start()
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
		binary := strings.Repeat("a", 64)
		m := newMetricLog()
		// The compatibility pair is ready only once a snapshot is published.
		cfg := service.Config{ServingEnabled: true, QualifiedBuildHashes: binary, QualifiedCodeHashes: binary + ":" + strings.Repeat("c", 64)}
		s := service.New(ctx, cfg, service.Dependencies{Store: &failingBuildStore{memorystore.NewMemory(store.Config{})}, Logger: discardLogger(), Metrics: m.metrics(),
			RefreshReleasePolicy: func() error { return errors.New("catalog unavailable") }})
		s.Start()
		if m.incrCount("app_attest.qualification.refresh_failed") != 1 || m.incrCount("app_attest.release_refresh_failed") != 1 {
			t.Fatal("start refresh failures not counted")
		}
		time.Sleep(authorization.RefreshInterval)
		synctest.Wait()
		if m.incrCount("app_attest.qualification.refresh_failed") != 2 || m.incrCount("app_attest.release_refresh_failed") != 2 {
			t.Fatal("periodic refresh failures not counted")
		}
		if s.ReleaseReady(readinessTestBuild(binary).Release) {
			t.Fatal("failed refresh published a snapshot")
		}
		cancel()
		synctest.Wait()
	})
}

func TestInventoryReconcilerRepeatsUntilCancelled(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		st := &workerStore{MemoryStore: memorystore.NewMemory(store.Config{})}
		s := service.New(ctx, service.Config{}, service.Dependencies{Store: st, Logger: discardLogger()})
		s.Start()
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
