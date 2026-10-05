package exchange_test

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/diagnostics"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	storagebudget "github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

type blockedDiagnosticArchive struct {
	*memorystore.MemoryStore
	entered, release chan struct{}
	reads, archives  atomic.Int32
}

func (a *blockedDiagnosticArchive) GetAppAttestAssertionDiagnostics(context.Context, string) (*store.AppAttestAssertionDiagnostics, error) {
	a.reads.Add(1)
	a.entered <- struct{}{}
	// The test controls completion so the admission assertion does not race
	// the 100 ms query timeout on a loaded test runner.
	<-a.release
	return nil, nil
}

func (a *blockedDiagnosticArchive) BeginAppAttestEvidence(ctx context.Context, e store.AppAttestEvidence) error {
	a.archives.Add(1)
	return a.MemoryStore.BeginAppAttestEvidence(ctx, e)
}

func TestLifecycleLookupDoesNotOccupyProofStorage(t *testing.T) {
	a := &blockedDiagnosticArchive{MemoryStore: memorystore.NewMemory(store.Config{}),
		entered: make(chan struct{}, 2), release: make(chan struct{})}
	budget, integrity := &storagebudget.Budget{}, &evidence.Integrity{}
	credential := &store.AppAttestShadowKey{KeyID: "key"}
	newReady := func() map[string]any {
		return map[string]any{"boot_time": time.Now().Unix(), "rebooted_since_last_success": true}
	}
	x := exchange.Attempt{Challenge: exchange.Challenge{Binding: transcript.Binding{Session: "session"}, Expected: "assertion", Credential: credential}, Rejection: "session_stopped", ReadyContext: newReady()}
	pipeline := exchange.NewPipeline(exchange.PipelineDependencies{Verification: exchange.Dependencies{Keys: a}, Archive: a,
		Provider: newSessionProvider("endpoint", "se"), Budget: budget, Scope: storagebudget.NewScope(budget), Integrity: integrity})
	var result exchange.ReplyResult
	done := make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(a.release) }) }
	defer func() {
		unblock()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("proof worker did not finish")
		}
	}()
	go func() {
		defer close(done)
		result = pipeline.Handle(t.Context(), x, protocol.AppAttestShadowPayload{Session: x.Challenge.Binding.Session, Action: "assertion", Proof: "malformed"})
	}()
	select {
	case <-a.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("diagnostic query did not start")
	}

	// All four archival permits remain available during the optional query.
	var releases []func()
	defer func() {
		for _, release := range releases {
			release()
		}
	}()
	for i := 0; i < 4; i++ {
		release, ok := budget.AcquireProof()
		if !ok {
			t.Fatalf("optional diagnostic read occupied proof storage slot %d", i+1)
		}
		releases = append(releases, release)
	}
	if release, ok := budget.AcquireProof(); ok {
		release()
		t.Fatal("proof storage exceeded its unchanged four-permit bound")
	}
	for _, release := range releases {
		release()
	}
	releases = nil

	// A second optional read skips immediately, clearing any stale flags.
	skipped := newReady()
	skippedDone := make(chan struct{})
	go func() { diagnostics.Derive(t.Context(), budget, a, credential, skipped); close(skippedDone) }()
	select {
	case <-skippedDone:
	case <-time.After(time.Second):
		t.Fatal("busy diagnostics queued behind another optional read")
	}
	if a.reads.Load() != 1 || skipped["rebooted_since_last_success"] != nil {
		t.Fatal("busy diagnostics must remain unknown without issuing another query")
	}
	unblock()
	<-done
	if a.archives.Load() != 1 || integrity.Dropped() != 0 || result.Outcome == "storage_busy" {
		t.Fatal("optional lookup prevented the proof from being archived")
	}
	// Completion releases the optional permit for subsequent attempts too.
	diagnostics.Derive(t.Context(), budget, a, credential, newReady())
	if a.reads.Load() != 2 {
		t.Fatal("optional diagnostic admission did not recover")
	}
}
