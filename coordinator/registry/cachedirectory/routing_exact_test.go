package cachedirectory

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestExactRoutingTrackerRemainsBoundedUnderConcurrency(t *testing.T) {
	tracker := newTestDirectory(time.Minute, 2)
	tracker.maxEntries = 128
	tracker.maxAttempts = 256
	now := time.Now()
	var workers sync.WaitGroup
	for worker := 0; worker < 16; worker++ {
		workers.Add(1)
		go func(worker int) {
			defer workers.Done()
			for index := 0; index < 200; index++ {
				key := fmt.Sprintf("key-%d-%d", worker, index)
				nonce := fmt.Sprintf("nonce-%d-%d", worker, index)
				tracker.mu.Lock()
				tracker.upsertHolderLocked(key, Holder[*testConnection]{
					ProviderID: fmt.Sprintf("provider-%d", worker),
					UpdatedAt:  now,
					ExpiresAt:  now.Add(time.Minute),
				})
				tracker.storeAttemptLocked(nonce, Attempt[*testConnection]{
					RequestID:  fmt.Sprintf("request-%d-%d", worker, index),
					ProviderID: fmt.Sprintf("provider-%d", worker),
					CreatedAt:  now.Add(time.Duration(worker*200+index) * time.Nanosecond),
					ExpiresAt:  now.Add(time.Minute),
				})
				tracker.enforceAttemptCapLocked()
				tracker.mu.Unlock()
			}
		}(worker)
	}
	workers.Wait()
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	if tracker.holderCount > tracker.maxEntries ||
		len(tracker.holders) > tracker.maxEntries ||
		len(tracker.attempts) > tracker.maxAttempts ||
		len(tracker.holderOrder) != tracker.holderCount ||
		len(tracker.attemptOrder) != len(tracker.attempts) {
		t.Fatalf(
			"tracker exceeded bounds: holders=%d keys=%d holder_heap=%d attempts=%d attempt_heap=%d",
			tracker.holderCount,
			len(tracker.holders),
			len(tracker.holderOrder),
			len(tracker.attempts),
			len(tracker.attemptOrder),
		)
	}
}
func TestExactRoutingHolderCapacityEvictionIsCounted(t *testing.T) {
	tracker := newTestDirectory(time.Minute, 1)
	now := time.Now()
	tracker.mu.Lock()
	tracker.upsertHolderLocked("boundary", Holder[*testConnection]{
		ProviderID: "first", UpdatedAt: now, ExpiresAt: now.Add(time.Minute),
	})
	tracker.upsertHolderLocked("boundary", Holder[*testConnection]{
		ProviderID: "second", UpdatedAt: now.Add(time.Second), ExpiresAt: now.Add(time.Minute),
	})
	added := tracker.holderAdded
	removed := tracker.holderRemoved[string(RemovalCapacityEviction)]
	count := tracker.holderCount
	tracker.mu.Unlock()
	if added != 2 || removed != 1 || count != 1 {
		t.Fatalf("capacity lifecycle added=%d removed=%d holders=%d", added, removed, count)
	}
}
