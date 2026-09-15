package store

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
)

func TestAppAttestShadowMemoryCounterAndOwnership(t *testing.T) {
	s := &MemoryStore{}
	ctx := context.Background()
	ok, err := s.InsertAppAttestShadowKey(ctx, AppAttestShadowKey{KeyID: "key", Owner: "owner", PublicKey: []byte{1}})
	if err != nil || !ok {
		t.Fatal(err)
	}
	ok, err = s.InsertAppAttestShadowKey(ctx, AppAttestShadowKey{KeyID: "key", Owner: "attacker"})
	if err != nil || ok {
		t.Fatal("overwrote ownership")
	}
	if ok, _ := s.AdvanceAppAttestShadowCounter(ctx, "key", "attacker", 1); ok {
		t.Fatal("wrong owner advanced counter")
	}
	var wins atomic.Int32
	var group sync.WaitGroup
	for i := 0; i < 20; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			if ok, _ := s.AdvanceAppAttestShadowCounter(ctx, "key", "owner", 1); ok {
				wins.Add(1)
			}
		}()
	}
	group.Wait()
	if wins.Load() != 1 {
		t.Fatalf("concurrent replay accepted %d times", wins.Load())
	}
	a, _ := s.GetAppAttestShadowKey(ctx, "key")
	a.PublicKey[0] = 7
	b, _ := s.GetAppAttestShadowKey(ctx, "key")
	if b.PublicKey[0] != 1 || b.Counter != 1 || b.Owner != "owner" {
		t.Fatalf("aliased/invalid state: %+v", b)
	}
	if _, ok := As[AppAttestShadowStore](&CachedStore{Store: s}); !ok {
		t.Fatal("cache hid shadow storage")
	}
}

func TestAppAttestShadowPostgresCounterAndRestart(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	key := AppAttestShadowKey{KeyID: "shadow-key", Owner: "owner", PublicKey: []byte{1, 2, 3}, AppID: "TEST.app", Environment: "production"}
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
	fresh := &PostgresStore{pool: s.pool}
	got, err := fresh.GetAppAttestShadowKey(ctx, key.KeyID)
	if err != nil || got == nil || got.Counter != 1 || got.Owner != key.Owner {
		t.Fatalf("read: %+v %v", got, err)
	}
	if ok, err := fresh.AdvanceAppAttestShadowCounter(ctx, key.KeyID, "wrong-owner", 2); err != nil || ok {
		t.Fatalf("owner: %v %v", ok, err)
	}
}
