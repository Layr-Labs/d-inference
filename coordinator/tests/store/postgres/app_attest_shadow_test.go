package postgres_test

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAppAttestShadowPostgresCounterAndRestart(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	key := store.AppAttestShadowKey{KeyID: "shadow-key", Owner: "owner", PublicKey: []byte{1, 2, 3}, AppID: "TEST.app", Environment: "production"}
	if ok, err := s.InsertAppAttestShadowKey(ctx, key); err != nil || !ok {
		t.Fatalf("insert: %v %v", ok, err)
	}
	if ok, err := s.InsertAppAttestShadowKey(ctx, key); err != nil || ok {
		t.Fatalf("duplicate: %v %v", ok, err)
	}
	var wins atomic.Int32
	var group sync.WaitGroup
	for i := 0; i < 20; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			if ok, err := s.AdvanceAppAttestShadowCounter(ctx, key.KeyID, key.Owner, 1); err != nil {
				t.Error(err)
			} else if ok {
				wins.Add(1)
			}
		}()
	}
	group.Wait()
	if wins.Load() != 1 {
		t.Fatalf("counter raced: %d", wins.Load())
	}
	// New wrapper has no process cache: persisted state remains authoritative.
	fresh := bindPostgresFixture(s.pool)
	got, err := fresh.GetAppAttestShadowKey(ctx, key.KeyID)
	if err != nil || got == nil || got.Counter != 1 || got.Owner != key.Owner {
		t.Fatalf("read: %+v %v", got, err)
	}
	if ok, err := fresh.AdvanceAppAttestShadowCounter(ctx, key.KeyID, "wrong-owner", 2); err != nil || ok {
		t.Fatalf("owner: %v %v", ok, err)
	}
}
