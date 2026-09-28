package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestMemoryFloorEpochLockCancellationAndReuse(t *testing.T) {
	s := NewMemory(Config{})
	held, release, done := make(chan struct{}), make(chan struct{}), make(chan error, 1)
	go func() {
		done <- s.WithEpochSettlementLock(context.Background(), "epoch", func() error { close(held); <-release; return nil })
	}()
	<-held
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	called := false
	err := s.WithEpochSettlementLock(ctx, "epoch", func() error { called = true; return nil })
	if !errors.Is(err, context.DeadlineExceeded) || called {
		t.Fatalf("blocked epoch ignored cancellation: called=%v err=%v", called, err)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if err := s.WithEpochSettlementLock(context.Background(), "epoch", func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	s.floorEpochMu.Lock()
	defer s.floorEpochMu.Unlock()
	if len(s.floorEpochs) != 0 {
		t.Fatal("idle epoch locks retained")
	}
}
