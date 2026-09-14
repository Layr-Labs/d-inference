package api

import (
	"context"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// These tests use the API's existing construction and lifecycle entry points,
// so their assertions also run against the source before owner extraction.
func TestTrustReuseManagerKeepsStartupStoreAndLiveMDMClient(t *testing.T) {
	srv, initial := trustReuseServer(t)
	defer srv.Close()
	if err := srv.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatal(err)
	}
	replacement := store.NewMemory(store.Config{})
	srv.store = replacement
	p := newTrustReuseProvider(t, srv, "bound-store", "bound-se", "bound-serial")
	if !srv.recordTrustReuse(p, "bound-se", "bound-serial", trHashA, true, true, "bound-udid") {
		t.Fatal("fresh verified evidence did not grant")
	}
	rows, err := initial.ListProviderTrustReuse(context.Background())
	if err != nil || len(rows) != 1 || rows[0].SEPubKey != "bound-se" {
		t.Fatalf("startup store did not receive evidence: rows=%+v err=%v", rows, err)
	}
	rows, err = replacement.ListProviderTrustReuse(context.Background())
	if err != nil || len(rows) != 0 {
		t.Fatalf("post-startup store replacement received evidence: rows=%+v err=%v", rows, err)
	}
	p.Mu().Lock()
	p.TrustLevel = registry.TrustSelfSigned
	p.Mu().Unlock()
	if srv.tryTrustReuseFastSkip(p.ID, p, goodFastSkipResp(), true) {
		t.Fatal("absent MDM client admitted reuse")
	}
	srv.mdmClient = dummyMDMClient()
	if !srv.tryTrustReuseFastSkip(p.ID, p, goodFastSkipResp(), true) {
		t.Fatal("owner did not observe the MDM client installed after construction")
	}
}

type trustShutdownStore struct {
	*store.MemoryStore
	mu     sync.Mutex
	stages []string
}

func (s *trustShutdownStore) AdvanceProviderTrustReuseCoverage(ctx context.Context, keys []string, until time.Time) error {
	s.mu.Lock()
	s.stages = append(s.stages, "device")
	s.mu.Unlock()
	return s.MemoryStore.AdvanceProviderTrustReuseCoverage(ctx, keys, until)
}

func (s *trustShutdownStore) AdvanceCodeAttestationCoverage(ctx context.Context, rows []store.CodeAttestation) error {
	s.mu.Lock()
	s.stages = append(s.stages, "application")
	s.mu.Unlock()
	return s.MemoryStore.AdvanceCodeAttestationCoverage(ctx, rows)
}

func TestTrustReuseShutdownKeepsAuthorityThroughCoverageAndRouteDrain(t *testing.T) {
	st := &trustShutdownStore{MemoryStore: store.NewMemory(store.Config{})}
	path := filepath.Join(t.TempDir(), "revocations.jsonl")
	srv := durableTrustReuseTestServer(t, st, path)
	if err := srv.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatal(err)
	}
	p := newTrustReuseProvider(t, srv, "shutdown", "shutdown-se", "shutdown-serial")
	if !srv.recordTrustReuse(p, "shutdown-se", "shutdown-serial", trHashA, true, true, "shutdown-udid") {
		t.Fatal("fresh evidence did not grant")
	}
	p.Mu().Lock()
	p.CodeAttested, p.FreshCodeAttested = true, true
	p.Version, p.APNsDeviceToken = "0.9.0", "shutdown-token"
	p.AttestationResult.BinaryHash = trHashA
	p.Mu().Unlock()
	srv.codeAttestThrottle.recordAttestedForProcess("shutdown-se", "0.9.0", "shutdown-token", p.PublicKey, trHashA)

	started, release, stopped := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	defer unblock()
	if !srv.routeTelemetry.Submit(func() { close(started); <-release }) {
		t.Fatal("could not enqueue the owned route worker")
	}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("route worker did not start")
	}
	go func() { srv.Close(); close(stopped) }()
	defer func() {
		unblock()
		select {
		case <-stopped:
		case <-time.After(3 * time.Second):
			t.Error("server shutdown did not finish after worker release")
		}
	}()

	// A non-full queue rejecting a valid offer proves Close has reached its
	// route-drain boundary. The blocked worker prevents it from finishing.
	deadline := time.Now().Add(time.Second)
	for srv.routeTelemetry.Submit(func() {}) {
		if time.Now().After(deadline) {
			t.Fatal("server did not reach the route shutdown boundary")
		}
		time.Sleep(time.Millisecond)
	}
	if srv.routeTelemetry.Depth() >= defaultTelemetrySinkCapacity {
		t.Fatal("queue filled before shutdown; closure was not observed")
	}
	st.mu.Lock()
	stages := append([]string(nil), st.stages...)
	st.mu.Unlock()
	if !reflect.DeepEqual(stages, []string{"device", "application"}) {
		t.Fatalf("coverage order before routing teardown = %v", stages)
	}

	contender := durableTrustReuseTestServer(t, st, path)
	defer contender.Close()
	if err := contender.SeedTrustReuseCache(context.Background()); err == nil || !strings.Contains(err.Error(), "another coordinator owns") {
		t.Fatalf("authority released while the route worker was still draining: %v", err)
	}
	unblock()
	select {
	case <-stopped:
	case <-time.After(3 * time.Second):
		t.Fatal("server did not finish shutdown")
	}
	successor := durableTrustReuseTestServer(t, st, path)
	defer successor.Close()
	if err := successor.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("authority did not transfer after shutdown: %v", err)
	}
}
