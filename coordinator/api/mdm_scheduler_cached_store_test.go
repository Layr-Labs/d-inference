package api

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Mirror of TestMDMSchedulerDuePagingCannotStarveLiveRowBehindDisconnectedPrefix
// over store.NewCached(store.NewMemory(...)), the shape main.go hands the
// server. The paged due-row scan is an optional verificationDuePageStore
// capability that a direct type assertion cannot see through the decorator;
// without store.As, loadDueRows silently falls back to re-reading page zero
// and the live row behind the disconnected prefix is never reseeded.
func TestMDMSchedulerDuePagingThroughCachedStore(t *testing.T) {
	base := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	due := base.Add(time.Hour)
	var clock atomic.Int64
	clock.Store(base.UnixNano())
	nowFn := func() time.Time { return time.Unix(0, clock.Load()).UTC() }

	cached := store.NewCached(store.NewMemory(store.Config{}), store.CacheConfig{})
	if _, direct := any(cached).(verificationDuePageStore); direct {
		t.Fatal("direct assertion on CachedStore succeeded; this test no longer exercises the wrapped path")
	}
	srv, sch := newSchedulerTestServerWithStore(t, cached, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 2,
		InitialSpreadMin: time.Hour, InitialSpreadMax: time.Hour,
	}, mdmSchedulerDeps{
		now: nowFn,
		jitter: func(time.Duration, time.Duration) time.Duration {
			return time.Hour
		},
	})
	if _, ok := store.As[verificationDuePageStore](sch.store); !ok {
		t.Fatal("store.As cannot find verificationDuePageStore through the scheduler's cached store")
	}

	for i := range 5 {
		_, err := cached.UpsertVerificationJob(context.Background(), store.VerificationJob{
			SEPubKey:      fmt.Sprintf("a-disconnected-%02d", i),
			Serial:        fmt.Sprintf("serial-disconnected-%02d", i),
			Kind:          store.VerificationTaskSecurityInfo,
			State:         store.VerificationStatePending,
			Priority:      store.VerificationPriorityFirstOrExpired,
			NextAttemptAt: due,
			UpdatedAt:     base,
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	first := schedulerTestProvider(t, srv, "paging-filler-1", "se-paging-filler-1")
	second := schedulerTestProvider(t, srv, "paging-filler-2", "se-paging-filler-2")
	firstGeneration := sch.Submit(
		context.Background(), first.ID, first, store.VerificationPriorityRefresh,
	)
	secondGeneration := sch.Submit(
		context.Background(), second.ID, second, store.VerificationPriorityRefresh,
	)
	live := schedulerTestProvider(t, srv, "paging-live", "z-se-paging-live")
	sch.Submit(
		context.Background(), live.ID, live, store.VerificationPriorityRefresh,
	)
	sch.ChallengeSettled(live, false)
	sch.Unbind("se-paging-filler-1", firstGeneration)
	sch.Unbind("se-paging-filler-2", secondGeneration)

	clock.Store(due.UnixNano())
	for range 4 {
		sch.loadDueRows()
	}
	sch.mu.Lock()
	reseeded := sch.jobs[verificationSchedulerKey(
		"z-se-paging-live", store.VerificationTaskSecurityInfo,
	)]
	offset := sch.dueScanOffset
	sch.mu.Unlock()
	if reseeded == nil {
		t.Fatalf("live queue-rejected row remained hidden behind the disconnected due-row prefix (dueScanOffset=%d): paged listing was not reached through the cached store", offset)
	}
	if !reseeded.record.NextAttemptAt.Equal(due) {
		t.Fatalf("paged reseed due = %s, want %s", reseeded.record.NextAttemptAt, due)
	}
}
