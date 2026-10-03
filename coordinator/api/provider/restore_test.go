package provider

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type restoreTrackingStore struct {
	store.Store
	lookups int
}

func (s *restoreTrackingStore) GetProviderForRestore(ctx context.Context, serial, key string, exclude []string) (*store.ProviderRecord, error) {
	s.lookups++
	return s.Store.GetProviderForRestore(ctx, serial, key, exclude)
}

func TestProviderRestoreLoadsAfterStartupAndNeverResurrectsHardware(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := &restoreTrackingStore{Store: memory.NewMemory(store.Config{})}
	reg := registry.New(logger)
	reg.SetStore(st)
	srv := newProviderFixture(t, Dependencies{Registry: reg, Store: st, Logger: logger})

	// History earned after Server creation must be visible at reconnect.
	chain, _ := json.Marshal([][]byte{[]byte("staged-only")})
	rec := store.ProviderRecord{ID: "prior", SerialNumber: "serial", SEPublicKey: "key", LastSeen: time.Now(), TrustLevel: string(registry.TrustHardware), Attested: true, MDAVerified: true, MDACertChain: chain, LifetimeTokensGenerated: 1234, AccountID: "owner"}
	if err := st.UpsertProvider(context.Background(), rec); err != nil {
		t.Fatal(err)
	}
	if err := st.UpsertReputation(context.Background(), "prior", store.ReputationRecord{TotalJobs: 12, SuccessfulJobs: 10}); err != nil {
		t.Fatal(err)
	}
	p := reg.Register("current", nil, &protocol.RegisterMessage{})
	p.SetAttested(true, registry.TrustSelfSigned)
	srv.RestorePersistedProviderState(context.Background(), p, "serial", "key")
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.TrustLevel != registry.TrustSelfSigned || p.MDAVerified || len(p.MDACertChain) != 0 {
		t.Fatalf("resurrected live hardware proof: trust=%s MDA=%v", p.TrustLevel, p.MDAVerified)
	}
	if p.Stats.TokensGenerated != 1234 || p.Reputation.TotalJobs != 12 || p.AccountID != "owner" {
		t.Fatalf("lost durable counters/account/reputation")
	}
}

func TestProviderRestoreNotReachedWithoutValidAttestation(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := &restoreTrackingStore{Store: memory.NewMemory(store.Config{})}
	reg := registry.New(logger)
	srv := newProviderFixture(t, Dependencies{Registry: reg, Store: st, Logger: logger})

	for _, evidence := range []json.RawMessage{nil, json.RawMessage(`{"bad":`)} {
		p := reg.Register(string(evidence)+"p", nil, &protocol.RegisterMessage{})
		srv.trust.VerifyProviderAttestation(context.Background(), p.ID, p, &protocol.RegisterMessage{Attestation: evidence})
	}
	if st.lookups != 0 {
		t.Fatal("looked up durable state before live attestation verification")
	}
}

type concurrentRestoreStore struct {
	store.Store
	entered chan struct{}
	release chan struct{}
}

func (s *concurrentRestoreStore) GetProviderForRestore(ctx context.Context, serial, key string, exclude []string) (*store.ProviderRecord, error) {
	s.entered <- struct{}{}
	select {
	case <-s.release:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	return s.Store.GetProviderForRestore(ctx, serial, key, exclude)
}

func TestProviderConcurrentReconnectsExcludeBothPartialRows(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	base := memory.NewMemory(store.Config{})
	now := time.Now()
	for _, rec := range []store.ProviderRecord{
		{ID: "history", SerialNumber: "serial", SEPublicKey: "se", LastSeen: now.Add(-time.Hour), LifetimeTokensGenerated: 700, AccountID: "owner", TrustLevel: string(registry.TrustHardware), MDAVerified: true},
		{ID: "one", SerialNumber: "serial", SEPublicKey: "se", LastSeen: now},
		{ID: "two", SerialNumber: "serial", SEPublicKey: "se", LastSeen: now.Add(time.Second)},
	} {
		if err := base.UpsertProvider(context.Background(), rec); err != nil {
			t.Fatal(err)
		}
	}
	st := &concurrentRestoreStore{Store: store.NewCached(base, store.DefaultCacheConfig()), entered: make(chan struct{}, 2), release: make(chan struct{})}
	reg := registry.New(logger)
	srv := newProviderFixture(t, Dependencies{Registry: reg, Store: st, Logger: logger})

	// Leave persistence detached: the deliberately pre-seeded partial rows must
	// remain visible until both concurrent lookup queries have their exclusions.
	reg.SetStore(nil)
	one := reg.Register("one", nil, &protocol.RegisterMessage{})
	two := reg.Register("two", nil, &protocol.RegisterMessage{})
	var wg sync.WaitGroup
	for _, p := range []*registry.Provider{one, two} {
		wg.Add(1)
		go func(p *registry.Provider) {
			defer wg.Done()
			srv.RestorePersistedProviderState(context.Background(), p, "serial", "se")
		}(p)
	}
	for i := 0; i < 2; i++ {
		select {
		case <-st.entered:
		case <-time.After(time.Second):
			t.Fatal("concurrent lookup did not enter")
		}
	}
	close(st.release)
	wg.Wait()
	for _, p := range []*registry.Provider{one, two} {
		p.Mu().Lock()
		if p.Stats.TokensGenerated != 700 || p.AccountID != "owner" || p.MDAVerified || p.TrustLevel != registry.TrustSelfSigned {
			t.Fatalf("partial/trusted restore: %+v", p.Stats)
		}
		p.Mu().Unlock()
	}
}

type arrivingRestoreStore struct {
	store.Store
	onFirst func()
	calls   int
}

func (s *arrivingRestoreStore) GetProviderForRestore(ctx context.Context, serial, key string, exclude []string) (*store.ProviderRecord, error) {
	s.calls++
	if s.calls == 1 {
		s.onFirst()
	}
	return s.Store.GetProviderForRestore(ctx, serial, key, exclude)
}
func TestProviderRestoreRechecksSessionsRegisteredDuringLookup(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	base := memory.NewMemory(store.Config{})
	reg := registry.New(logger)
	if err := base.UpsertProvider(context.Background(), store.ProviderRecord{ID: "history", SerialNumber: "serial", SEPublicKey: "se", LastSeen: time.Now().Add(-time.Hour), LifetimeTokensGenerated: 700}); err != nil {
		t.Fatal(err)
	}
	p := reg.Register("current", nil, &protocol.RegisterMessage{})
	st := &arrivingRestoreStore{Store: base, onFirst: func() {
		reg.Register("late", nil, &protocol.RegisterMessage{})
		if err := base.UpsertProvider(context.Background(), store.ProviderRecord{ID: "late", SerialNumber: "serial", SEPublicKey: "se", LastSeen: time.Now()}); err != nil {
			t.Fatal(err)
		}
	}}
	srv := newProviderFixture(t, Dependencies{Registry: reg, Store: st, Logger: logger})

	// Keep registration from asynchronously overwriting the seeded late row.
	reg.SetStore(nil)
	srv.RestorePersistedProviderState(context.Background(), p, "serial", "se")
	if st.calls != 2 || p.Stats.TokensGenerated != 700 {
		t.Fatalf("late active row accepted: calls=%d tokens=%d", st.calls, p.Stats.TokensGenerated)
	}
}
