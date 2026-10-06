package memory_test

import (
	"context"
	"errors"
	"testing"
	"time"

	epochlocks "github.com/eigeninference/d-inference/coordinator/internal/store/epochlocks"
)

func TestMemoryFloorEpochLockCancellationAndReuse(t *testing.T) {
	s := &epochlocks.Owner{}
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
	if s.Len() != 0 {
		t.Fatal("idle epoch locks retained")
	}
}
