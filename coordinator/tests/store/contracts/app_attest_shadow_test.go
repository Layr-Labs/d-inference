package store_test

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestAppAttestShadowMemoryCounterAndOwnership(t *testing.T) {
	s := &memory.MemoryStore{}
	ctx := context.Background()
	ok, err := s.InsertAppAttestShadowKey(ctx, store.AppAttestShadowKey{KeyID: "key", Owner: "owner", PublicKey: []byte{1}})
	if err != nil || !ok {
		t.Fatal(err)
	}
	ok, err = s.InsertAppAttestShadowKey(ctx, store.AppAttestShadowKey{KeyID: "key", Owner: "attacker"})
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
	if _, ok := store.As[store.AppAttestShadowStore](&store.CachedStore{Store: s}); !ok {
		t.Fatal("cache hid shadow storage")
	}
}
