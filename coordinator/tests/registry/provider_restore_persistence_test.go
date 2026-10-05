package registry_test

import (
	"context"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type orderedRestoreStore struct {
	store.Store
	entered chan store.ProviderRecord
	release chan struct{}
	written chan store.ProviderRecord
	once    sync.Once
}

func (s *orderedRestoreStore) UpsertProvider(ctx context.Context, rec store.ProviderRecord) error {
	return s.write(ctx, rec, func() error { return s.Store.UpsertProvider(ctx, rec) })
}
func (s *orderedRestoreStore) UpsertProviderWithReputation(ctx context.Context, rec store.ProviderRecord, rep store.ReputationRecord) error {
	return s.write(ctx, rec, func() error { return s.Store.UpsertProviderWithReputation(ctx, rec, rep) })
}
func (s *orderedRestoreStore) write(ctx context.Context, rec store.ProviderRecord, apply func() error) error {
	blocked := false
	s.once.Do(func() { blocked = true; s.entered <- rec })
	if blocked {
		select {
		case <-s.release:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	err := apply()
	s.written <- rec
	return err
}
func waitPersisted(t *testing.T, ch <-chan store.ProviderRecord) store.ProviderRecord {
	t.Helper()
	select {
	case rec := <-ch:
		return rec
	case <-time.After(2 * time.Second):
		t.Fatal("persist did not finish")
		return store.ProviderRecord{}
	}
}

func restorePersistenceRegistry() (*production.Registry, map[string]*production.ProviderPersistence) {
	owners := make(map[string]*production.ProviderPersistence)
	r := production.NewWithDependencies(slog.New(slog.NewTextHandler(io.Discard, nil)), production.Dependencies{
		ProviderPersistence: func(id string, actual *production.ProviderPersistence) production.ProviderPersistenceOperations {
			owners[id] = actual
			return actual
		},
	})
	return r, owners
}

// Drain registration's initial write, then arm the same store barrier for the
// explicit snapshot under test. The reputation operation waits on the actual
// persistence serialization, including the session touch after the write.
func rearmRestoreStore(t *testing.T, st *orderedRestoreStore, owner *production.ProviderPersistence) {
	t.Helper()
	waitPersisted(t, st.entered)
	close(st.release)
	waitPersisted(t, st.written)
	owner.PersistReputation()
	st.once = sync.Once{}
	st.release = make(chan struct{})
}

func TestProviderIncompleteIdentityRemainsUnpublishedAfterDisconnect(t *testing.T) {
	base := memory.NewMemory(store.Config{})
	if err := base.UpsertProvider(context.Background(), store.ProviderRecord{ID: "history", SerialNumber: "serial", SEPublicKey: "se", LastSeen: time.Now().Add(-time.Hour), LifetimeTokensGenerated: 700}); err != nil {
		t.Fatal(err)
	}
	st := &orderedRestoreStore{Store: base, entered: make(chan store.ProviderRecord, 1), release: make(chan struct{}), written: make(chan store.ProviderRecord, 4)}
	r, owners := restorePersistenceRegistry()
	r.SetStore(st)
	p := r.Register("pending", nil, &protocol.RegisterMessage{})
	rearmRestoreStore(t, st, owners[p.ID])
	// Reproduce the dangerous state: the initial async snapshot runs AFTER SE
	// evidence arrived but BEFORE history restoration completed.
	p.Mu().Lock()
	p.AttestationResult = &attestation.VerificationResult{SerialNumber: "serial", PublicKey: "se"}
	p.Status = production.StatusOnline
	p.Mu().Unlock()
	r.PersistProvider(p)
	first := waitPersisted(t, st.entered)
	if first.SerialNumber != "" || first.SEPublicKey != "" {
		t.Fatal("partial state published restore identity")
	}
	p.Mu().Lock()
	p.Status = production.StatusOffline
	p.Mu().Unlock()
	r.PersistProvider(p) // disconnect persistence can finish after removal from live IDs
	close(st.release)
	for i := 0; i < 2; i++ {
		rec := waitPersisted(t, st.written)
		if rec.SerialNumber != "" || rec.SEPublicKey != "" {
			t.Fatal("disconnected pending row became a restore candidate")
		}
	}
	got, err := base.GetProviderForRestore(context.Background(), "serial", "se", nil)
	if err != nil || got == nil || got.ID != "history" {
		t.Fatalf("partial row shadowed history: %+v %v", got, err)
	}
}

func TestProviderInitialPersistCannotOverwriteCompletedRestore(t *testing.T) {
	base := memory.NewMemory(store.Config{})
	st := &orderedRestoreStore{Store: base, entered: make(chan store.ProviderRecord, 1), release: make(chan struct{}), written: make(chan store.ProviderRecord, 4)}
	r, owners := restorePersistenceRegistry()
	r.SetStore(st)
	p := r.Register("current", nil, &protocol.RegisterMessage{})
	waitPersisted(t, st.entered) // initial write is blocked before committing
	p.Mu().Lock()
	if owners[p.ID].CanPublishLocked() {
		t.Fatal("registration did not protect incomplete restoration")
	}
	p.AttestationResult = &attestation.VerificationResult{SerialNumber: "serial", PublicKey: "se"}
	p.Stats.TokensGenerated = 700
	p.Reputation.TotalJobs = 12
	p.AccountID = "owner"
	p.Mu().Unlock()
	p.CompleteProviderStateRestore()
	r.PersistProvider(p)
	close(st.release)
	waitPersisted(t, st.written)
	waitPersisted(t, st.written)
	got, err := base.GetProviderRecord(context.Background(), "current")
	if err != nil || got.SerialNumber != "serial" || got.SEPublicKey != "se" || got.LifetimeTokensGenerated != 700 || got.AccountID != "owner" {
		t.Fatalf("late initial persist clobbered complete state: %+v %v", got, err)
	}
}

// Disconnect may queue reputation persistence while restore is blocked on its
// store read. No pending zero snapshot may survive to overwrite the completed
// record's reputation, and identity+reputation become visible together.
func TestProviderPendingReputationCannotOverwriteCompletedRestore(t *testing.T) {
	base := memory.NewMemory(store.Config{})
	st := &orderedRestoreStore{Store: base, entered: make(chan store.ProviderRecord, 1), release: make(chan struct{}), written: make(chan store.ProviderRecord, 4)}
	r, owners := restorePersistenceRegistry()
	r.SetStore(st)
	p := r.Register("pending-reputation", nil, &protocol.RegisterMessage{})
	rearmRestoreStore(t, st, owners[p.ID])
	p.Mu().Lock()
	p.AttestationResult = &attestation.VerificationResult{SerialNumber: "serial", PublicKey: "se"}
	p.Mu().Unlock()
	owners[p.ID].PersistReputation() // the exact zero snapshot that disconnect used to publish
	if _, err := base.GetReputation(context.Background(), p.ID); err == nil {
		t.Fatal("pending reputation was persisted")
	}
	r.PersistProvider(p)
	waitPersisted(t, st.entered) // the real initial write holds persistence serialization
	done := make(chan struct{})
	go func() { owners[p.ID].PersistReputation(); close(done) }() // queued behind initial persistence
	p.Mu().Lock()
	p.Reputation.TotalJobs = 12
	p.Stats.TokensGenerated = 700
	p.Mu().Unlock()
	p.CompleteProviderStateRestore()
	close(st.release)
	<-done
	r.PersistProvider(p)
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		rec, err := base.GetProviderForRestore(context.Background(), "serial", "se", nil)
		if err == nil && rec != nil {
			rep, err := base.GetReputation(context.Background(), rec.ID)
			if err != nil || rep.TotalJobs != 12 || rec.LifetimeTokensGenerated != 700 {
				t.Fatalf("completed identity has incomplete reputation: %+v %v", rep, err)
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("completed state was not published")
}

type failedRestoreReputationStore struct{ store.Store }

func (s failedRestoreReputationStore) GetReputation(context.Context, string) (*store.ReputationRecord, error) {
	return nil, io.ErrUnexpectedEOF
}
func TestProviderReputationReadFailureKeepsRestorePending(t *testing.T) {
	base := memory.NewMemory(store.Config{})
	r, owners := restorePersistenceRegistry()
	r.SetStore(failedRestoreReputationStore{base})
	p := r.Register("new", nil, &protocol.RegisterMessage{})
	if err := r.RestoreProviderState(p, &store.ProviderRecord{ID: "history", LifetimeTokensGenerated: 700}); err == nil {
		t.Fatal("ignored reputation read error")
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if owners[p.ID].CanPublishLocked() || p.Stats.TokensGenerated != 0 {
		t.Fatal("failed lookup completed or partially modified restoration")
	}
}
