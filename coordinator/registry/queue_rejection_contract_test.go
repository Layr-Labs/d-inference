package registry

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"
)

func TestQueueRejectionReleasesAssignmentBeforeNotification(t *testing.T) {
	for _, path := range []string{"explicit-reason", "stale-pop", "stale-sweep", "unservable-model"} {
		for _, buffered := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/buffered=%v", path, buffered), func(t *testing.T) {
				q := NewRequestQueue(2, time.Minute)
				req := &QueuedRequest{RequestID: "rejected", Model: "model"}
				if err := q.Enqueue(req); err != nil {
					t.Fatal(err)
				}
				req.EnqueuedAt = time.Now().Add(-2 * time.Minute)
				if buffered {
					req.ResponseCh <- nil
				}
				cleanupCalls := 0
				if !req.offerAssignment(&Provider{ID: "reserved"}, func() {
					cleanupCalls++
					select {
					case <-req.Done():
					default:
						t.Error("rejection must mark done before releasing its assignment")
					}
					if !buffered && len(req.ResponseCh) != 0 {
						t.Error("waiter notified before reservation cleanup")
					}
				}) {
					t.Fatal("fixture assignment refused")
				}
				want := ErrQueueTimeout
				switch path {
				case "explicit-reason":
					want = ErrQueueToolConstraintUnavailable
					req.failWithReason(want)
				case "stale-pop":
					if got := q.PopNextFresh(req.Model); got != nil {
						t.Fatal("stale request returned as fresh")
					}
				case "stale-sweep":
					if got := q.QueuedModels(); len(got) != 0 {
						t.Fatal("stale model survived sweep")
					}
				case "unservable-model":
					wantFailed := 1
					if buffered {
						wantFailed = 0
					}
					if got := q.FailQueuedRequestsForModel(req.Model, nil); got != wantFailed {
						t.Fatalf("new notifications=%d, want %d", got, wantFailed)
					}
				}
				if provider, err := q.WaitForProviderContext(context.Background(), req); provider != nil || !errors.Is(err, want) {
					t.Fatalf("waiter got (%v,%v), want nil,%v", provider, err, want)
				}
				req.markDone()
				if cleanupCalls != 1 {
					t.Fatalf("cleanup ran %d times, want 1", cleanupCalls)
				}
			})
		}
	}
}
