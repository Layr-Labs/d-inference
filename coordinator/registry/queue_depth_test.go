package registry

// Capacity-derived queue depth: the per-model depth follows the cached
// warm-pool snapshot — clamp(ceil(C × 3s / E[S]), 8, 512) — and keeps the
// static default without a fresh snapshot. An explicit
// EIGENINFERENCE_QUEUE_MAX_DEPTH is an operator ceiling on the dynamic depth.

import (
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

func TestCapacityQueueDepth(t *testing.T) {
	cases := []struct {
		name      string
		snap      WarmPoolSnapshot
		wantDepth int
		wantOK    bool
	}{
		// 5 boxes × 1 slot, 20s per request: the fleet drains 0.75 requests
		// in 3s — floor to 8 so a niche model still absorbs a small burst.
		{"niche fleet floors at 8", WarmPoolSnapshot{WarmProviders: 5, QualityConcurrency: 1, ServiceTime: 20 * time.Second}, 8, true},
		// 50 × 2 = 100 concurrent, 20s: 100 × 3 / 20 = 15.
		{"mid fleet is proportional", WarmPoolSnapshot{WarmProviders: 50, QualityConcurrency: 2, ServiceTime: 20 * time.Second}, 15, true},
		// 1000 × 3 = 3000 concurrent, 20s: 450 — under the cap.
		{"large fleet under cap", WarmPoolSnapshot{WarmProviders: 1000, QualityConcurrency: 3, ServiceTime: 20 * time.Second}, 450, true},
		// 1000 × 5 = 5000 concurrent, 10s: 1500 → capped at 512.
		{"huge fleet caps at 512", WarmPoolSnapshot{WarmProviders: 1000, QualityConcurrency: 5, ServiceTime: 10 * time.Second}, 512, true},
		{"no warm providers", WarmPoolSnapshot{WarmProviders: 0, QualityConcurrency: 4, ServiceTime: 20 * time.Second}, 0, false},
		{"unknown quality concurrency", WarmPoolSnapshot{WarmProviders: 10, QualityConcurrency: 0, ServiceTime: 20 * time.Second}, 0, false},
		{"no service time", WarmPoolSnapshot{WarmProviders: 10, QualityConcurrency: 4}, 0, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			depth, ok := capacityQueueDepth(tc.snap)
			if ok != tc.wantOK || depth != tc.wantDepth {
				t.Fatalf("capacityQueueDepth(%+v) = (%d, %v), want (%d, %v)", tc.snap, depth, ok, tc.wantDepth, tc.wantOK)
			}
		})
	}
}

func seedWarmPoolSnapshots(t *testing.T, reg *Registry, at time.Time, snaps ...WarmPoolSnapshot) {
	t.Helper()
	reg.ConfigureWarmPool(testWarmPoolConfig())
	reg.mu.RLock()
	controller := reg.warmPool
	reg.mu.RUnlock()
	controller.storeSnapshots(snaps, at)
}

func enqueueN(t *testing.T, q *RequestQueue, model string, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		req := &QueuedRequest{
			RequestID:  fmt.Sprintf("%s-%d", model, i),
			Model:      model,
			ResponseCh: make(chan *Provider, 1),
		}
		if err := q.Enqueue(req); err != nil {
			t.Fatalf("enqueue %d/%d for %s: %v", i+1, n, model, err)
		}
	}
}

// TestQueueDepthFollowsWarmPoolSnapshot: the registry's queue sizes each
// model from its snapshot — a niche model floors at 8, a huge fleet caps at
// 512 — and Enqueue enforces that depth (8 succeed, the 9th is ErrQueueFull),
// while a model the controller has not observed keeps the static default.
func TestQueueDepthFollowsWarmPoolSnapshot(t *testing.T) {
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_DEPTH", "")
	reg := New(testLogger())
	seedWarmPoolSnapshots(t, reg, time.Now(),
		WarmPoolSnapshot{Model: "niche", WarmProviders: 5, QualityConcurrency: 1, ServiceTime: 20 * time.Second},
		WarmPoolSnapshot{Model: "huge", WarmProviders: 1000, QualityConcurrency: 5, ServiceTime: 10 * time.Second},
		WarmPoolSnapshot{Model: "no-capacity", WarmProviders: 0, QualityConcurrency: 0},
	)
	q := reg.Queue()

	if got := q.MaxSizeFor("niche"); got != queueDepthMin {
		t.Fatalf("niche depth = %d, want floor %d", got, queueDepthMin)
	}
	if got := q.MaxSizeFor("huge"); got != queueDepthMax {
		t.Fatalf("huge depth = %d, want cap %d", got, queueDepthMax)
	}
	if got := q.MaxSizeFor("no-capacity"); got != defaultQueueMaxDepth {
		t.Fatalf("no-capacity depth = %d, want default %d", got, defaultQueueMaxDepth)
	}
	if got := q.MaxSizeFor("never-seen"); got != defaultQueueMaxDepth {
		t.Fatalf("unobserved model depth = %d, want default %d", got, defaultQueueMaxDepth)
	}

	// Enqueue enforces the dynamic depth, not the static 32.
	enqueueN(t, q, "niche", queueDepthMin)
	overflow := &QueuedRequest{RequestID: "niche-overflow", Model: "niche", ResponseCh: make(chan *Provider, 1)}
	if err := q.Enqueue(overflow); !errors.Is(err, ErrQueueFull) {
		t.Fatalf("enqueue #%d on the niche model = %v, want ErrQueueFull at the capacity-derived depth", queueDepthMin+1, err)
	}
	// A model with plenty of capacity accepts well past the static default.
	enqueueN(t, q, "huge", defaultQueueMaxDepth+1)
}

// TestQueueDepthStaleSnapshotKeepsDefault: a snapshot older than the freshness
// bound (controller not running) must not size the queue.
func TestQueueDepthStaleSnapshotKeepsDefault(t *testing.T) {
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_DEPTH", "")
	reg := New(testLogger())
	seedWarmPoolSnapshots(t, reg, time.Now().Add(-2*warmPoolSnapshotFreshness),
		WarmPoolSnapshot{Model: "huge", WarmProviders: 1000, QualityConcurrency: 5, ServiceTime: 10 * time.Second},
	)
	if got := reg.Queue().MaxSizeFor("huge"); got != defaultQueueMaxDepth {
		t.Fatalf("stale-snapshot depth = %d, want default %d", got, defaultQueueMaxDepth)
	}
	if _, ok := reg.LatestWarmPoolSnapshotFor("huge"); ok {
		t.Fatal("LatestWarmPoolSnapshotFor returned a stale snapshot")
	}
}

// TestQueueDepthNoWarmPoolKeepsDefault: a registry without a configured
// controller (the dev/test default) keeps the static depth.
func TestQueueDepthNoWarmPoolKeepsDefault(t *testing.T) {
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_DEPTH", "")
	reg := New(testLogger())
	if reg.Queue().DepthFor == nil {
		t.Fatal("New must wire RequestQueue.DepthFor")
	}
	if got := reg.Queue().MaxSizeFor("any"); got != defaultQueueMaxDepth {
		t.Fatalf("depth without a warm pool = %d, want %d", got, defaultQueueMaxDepth)
	}
}

// TestQueueDepthEnvOverrideIsCeiling: an explicit EIGENINFERENCE_QUEUE_MAX_DEPTH
// caps the dynamic depth (and remains the depth without a snapshot) — prod
// pins 8, so the dynamic depth is inert there until an operator raises it.
func TestQueueDepthEnvOverrideIsCeiling(t *testing.T) {
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_DEPTH", "16")
	reg := New(testLogger())
	seedWarmPoolSnapshots(t, reg, time.Now(),
		WarmPoolSnapshot{Model: "huge", WarmProviders: 1000, QualityConcurrency: 5, ServiceTime: 10 * time.Second},
		WarmPoolSnapshot{Model: "niche", WarmProviders: 5, QualityConcurrency: 1, ServiceTime: 20 * time.Second},
	)
	q := reg.Queue()
	if got := q.MaxSizeFor("huge"); got != 16 {
		t.Fatalf("huge depth under env ceiling = %d, want 16", got)
	}
	// Below the ceiling the dynamic value stands.
	if got := q.MaxSizeFor("niche"); got != queueDepthMin {
		t.Fatalf("niche depth under env ceiling = %d, want %d", got, queueDepthMin)
	}
	if got := q.MaxSizeFor("never-seen"); got != 16 {
		t.Fatalf("unobserved depth under env = %d, want 16", got)
	}
	enqueueN(t, q, "huge", 16)
	overflow := &QueuedRequest{RequestID: "huge-overflow", Model: "huge", ResponseCh: make(chan *Provider, 1)}
	if err := q.Enqueue(overflow); !errors.Is(err, ErrQueueFull) {
		t.Fatalf("enqueue #17 under a 16 ceiling = %v, want ErrQueueFull", err)
	}
	// The prod pin: ceiling 8 makes the dynamic depth exactly inert.
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_DEPTH", "8")
	reg8 := New(testLogger())
	seedWarmPoolSnapshots(t, reg8, time.Now(),
		WarmPoolSnapshot{Model: "huge", WarmProviders: 1000, QualityConcurrency: 5, ServiceTime: 10 * time.Second},
	)
	if got := reg8.Queue().MaxSizeFor("huge"); got != 8 {
		t.Fatalf("huge depth under the prod ceiling 8 = %d, want 8", got)
	}
}

// TestQueueDepthUnsetEnvIsNotACeiling: the default depth must not silently cap
// the dynamic depth at 32 — only an explicit env value is a ceiling.
func TestQueueDepthUnsetEnvIsNotACeiling(t *testing.T) {
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_DEPTH", "")
	q := NewRequestQueueFromEnv()
	if q.depthCeiling != 0 || q.MaxSize() != defaultQueueMaxDepth {
		t.Fatalf("depthCeiling = %d, MaxSize = %d with the env unset, want 0 / %d", q.depthCeiling, q.MaxSize(), defaultQueueMaxDepth)
	}
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_DEPTH", "0")
	if q := NewRequestQueueFromEnv(); q.depthCeiling != 0 {
		t.Fatalf("depthCeiling = %d for a non-positive env value, want 0", q.depthCeiling)
	}
}
