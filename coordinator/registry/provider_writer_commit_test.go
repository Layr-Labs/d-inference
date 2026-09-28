package registry

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

func commitTestWriter(t *testing.T, write func([]byte) error) *providerWriter {
	t.Helper()
	w := &providerWriter{queue: make(chan *providerWriteRequest, 4), control: make(chan *providerWriteRequest, 4), stop: make(chan struct{}), done: make(chan struct{}), writeFrameForTest: write}
	go w.run()
	t.Cleanup(w.closeNow)
	return w
}

func commitTestRequest(beforeWrite func() error) *providerWriteRequest {
	return &providerWriteRequest{builder: func(time.Time) ([]byte, error) { return []byte("inference"), nil }, beforeWrite: beforeWrite}
}

func TestProviderWriterPreparedAuthorizationRejectionNeverCommits(t *testing.T) {
	var prepared, wrote atomic.Bool
	w := commitTestWriter(t, func([]byte) error { wrote.Store(true); return nil })
	denied := errors.New("authorization denied")
	metadata, err := w.writeRequest(context.Background(), commitTestRequest(func() error {
		if !prepared.Load() {
			t.Error("authorization ran before owner acknowledged preparation")
		}
		return denied
	}), false, func(metadata TextFrameWriteMetadata) {
		if metadata.Committed {
			t.Error("preparation already claimed commitment")
		}
		prepared.Store(true)
	})
	if !errors.Is(err, denied) || metadata.DequeuedAt.IsZero() || metadata.Committed || wrote.Load() {
		t.Fatalf("rejected preparation committed: metadata=%+v err=%v wrote=%v", metadata, err, wrote.Load())
	}
}

func TestProviderWriterCancellationDuringAuthorizationDoesNotCommitOrClose(t *testing.T) {
	authorizing, release := make(chan struct{}), make(chan struct{})
	var inferenceWrites atomic.Int32
	w := commitTestWriter(t, func(data []byte) error {
		if string(data) == "inference" {
			inferenceWrites.Add(1)
		}
		return nil
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	type result struct {
		metadata TextFrameWriteMetadata
		err      error
	}
	done := make(chan result, 1)
	go func() {
		metadata, err := w.writeRequest(ctx, commitTestRequest(func() error { close(authorizing); <-release; return nil }), false, nil)
		done <- result{metadata, err}
	}()
	<-authorizing
	cancel()
	select {
	case got := <-done:
		if got.err != context.Canceled || got.metadata.Committed || got.metadata.DequeuedAt.IsZero() {
			t.Fatalf("uncommitted cancellation = %+v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("authorization wait blocked cancellation")
	}
	if w.dead.Load() {
		t.Fatal("cancellation before handoff closed healthy socket")
	}
	close(release)
	if err := w.writeControl(context.Background(), []byte("barrier")); err != nil {
		t.Fatal(err)
	}
	if inferenceWrites.Load() != 0 {
		t.Fatal("canceled authorization later wrote inference")
	}
}

func TestProviderWriterStopDuringAuthorizationDoesNotCommit(t *testing.T) {
	authorizing, release := make(chan struct{}), make(chan struct{})
	var wrote atomic.Bool
	w := commitTestWriter(t, func([]byte) error { wrote.Store(true); return nil })
	type result struct {
		metadata TextFrameWriteMetadata
		err      error
	}
	done := make(chan result, 1)
	go func() {
		metadata, err := w.writeRequest(context.Background(), commitTestRequest(func() error { close(authorizing); <-release; return nil }), false, nil)
		done <- result{metadata, err}
	}()
	<-authorizing
	w.closeNow()
	close(release)
	select {
	case got := <-done:
		if !errors.Is(got.err, errProviderWriterStopped) || got.metadata.Committed || wrote.Load() {
			t.Fatalf("stopped preparation committed: %+v wrote=%v", got, wrote.Load())
		}
	case <-time.After(time.Second):
		t.Fatal("writer stop did not resolve preparation")
	}
}

func TestProviderWriterSocketFailureRetainsAuthorizedCommit(t *testing.T) {
	failure := errors.New("socket write failed")
	w := commitTestWriter(t, func([]byte) error { return failure })
	metadata, err := w.writeRequest(context.Background(), commitTestRequest(func() error { return nil }), false, nil)
	if !errors.Is(err, failure) || !metadata.Committed || metadata.DequeuedAt.IsZero() {
		t.Fatalf("socket handoff lost: metadata=%+v err=%v", metadata, err)
	}
}

func TestProviderWriterRejectedCancellationRetainsUncommittedResult(t *testing.T) {
	rejected, release := make(chan struct{}), make(chan struct{})
	defer close(release)
	w := commitTestWriter(t, func([]byte) error { t.Error("rejected frame reached socket"); return nil })
	w.afterWriteRejectedForTest = func() { close(rejected); <-release }
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	denied := errors.New("authorization denied")
	type result struct {
		metadata TextFrameWriteMetadata
		err      error
	}
	done := make(chan result, 1)
	go func() {
		metadata, err := w.writeRequest(ctx, commitTestRequest(func() error { return denied }), false, nil)
		done <- result{metadata, err}
	}()
	<-rejected
	cancel()
	select {
	case got := <-done:
		if !errors.Is(got.err, denied) || got.metadata.Committed {
			t.Fatalf("cancellation misreported denial: %+v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("rejection publication blocked cancellation")
	}
}
