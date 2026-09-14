package registry

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestNewRequestQueueFromEnvDefaults(t *testing.T) {
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_DEPTH", "")
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_WAIT", "")

	q := NewRequestQueueFromEnv()
	if q.MaxSize() != 32 {
		t.Fatalf("MaxSize() = %d, want default 32", q.MaxSize())
	}
	if q.queue.MaxWait() != 120*time.Second {
		t.Fatalf("maxWait = %v, want default 120s", q.queue.MaxWait())
	}
}

func TestNewRequestQueueFromEnvOverrides(t *testing.T) {
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_DEPTH", "7")
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_WAIT", "45s")

	q := NewRequestQueueFromEnv()
	if q.MaxSize() != 7 {
		t.Fatalf("MaxSize() = %d, want 7", q.MaxSize())
	}
	if q.queue.MaxWait() != 45*time.Second {
		t.Fatalf("maxWait = %v, want 45s", q.queue.MaxWait())
	}
}

func TestNewRequestQueueFromEnvRejectsInvalidValues(t *testing.T) {
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_DEPTH", "0")
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_WAIT", "-5s")

	q := NewRequestQueueFromEnv()
	if q.MaxSize() != 32 {
		t.Fatalf("MaxSize() = %d, want default 32 for non-positive depth", q.MaxSize())
	}
	if q.queue.MaxWait() != 120*time.Second {
		t.Fatalf("maxWait = %v, want default 120s for non-positive wait", q.queue.MaxWait())
	}

	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_DEPTH", "not-a-number")
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_WAIT", "soon")
	q = NewRequestQueueFromEnv()
	if q.MaxSize() != 32 || q.queue.MaxWait() != 120*time.Second {
		t.Fatalf("malformed env -> (%d, %v), want defaults (32, 120s)", q.MaxSize(), q.queue.MaxWait())
	}
}

func TestQueuedRequestGetsProviderWhenIdle(t *testing.T) {
	q := NewRequestQueue(10, 5*time.Second)

	req := &QueuedRequest{
		RequestID:  "req-1",
		Model:      "test-model",
		ResponseCh: make(chan *Provider, 1),
	}

	if err := q.Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	// Simulate a provider becoming idle and being assigned.
	provider := &Provider{
		ID:     "p1",
		Status: StatusOnline,
		Models: []protocol.ModelInfo{{ID: "test-model"}},
	}

	// Send provider on the response channel in a goroutine.
	go func() {
		time.Sleep(50 * time.Millisecond)
		if !req.offerAssignment(provider, nil) {
			return
		}
		req.ResponseCh <- provider
	}()

	// WaitForProviderContext should succeed.
	p, err := q.WaitForProviderContext(context.Background(), req)
	if err != nil {
		t.Fatalf("WaitForProviderContext: %v", err)
	}
	if p == nil {
		t.Fatal("expected non-nil provider")
	}
	if p.ID != "p1" {
		t.Errorf("provider id = %q, want p1", p.ID)
	}
}

func TestQueueTimeoutReturnsError(t *testing.T) {
	q := NewRequestQueue(10, 100*time.Millisecond)

	req := &QueuedRequest{
		RequestID:  "req-timeout",
		Model:      "test-model",
		ResponseCh: make(chan *Provider, 1),
	}

	if err := q.Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	// No provider becomes available — should timeout.
	_, err := q.WaitForProviderContext(context.Background(), req)
	if !errors.Is(err, ErrQueueTimeout) {
		t.Errorf("expected ErrQueueTimeout, got %v", err)
	}

	// Queue should be empty after timeout cleanup.
	if q.QueueSize("test-model") != 0 {
		t.Errorf("queue size after timeout = %d, want 0", q.QueueSize("test-model"))
	}
}

// TestFailQueuedRequestsForModelSkipsSelfRoute verifies that a PUBLIC unservable
// verdict fails public waiters but leaves exclusive self-route waiters queued —
// their own (busy) machine may still serve them.
func TestFailQueuedRequestsForModelSkipsSelfRoute(t *testing.T) {
	q := NewRequestQueue(10, 30*time.Second)
	model := "queue-self-route"

	public := &QueuedRequest{
		RequestID:  "pub",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending:    &PendingRequest{RequestID: "pub", Model: model},
	}
	selfRoute := &QueuedRequest{
		RequestID:  "self",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending:    &PendingRequest{RequestID: "self", Model: model, SelfRouteOnly: true, OwnerAccountID: "acct-A"},
	}
	if err := q.Enqueue(public); err != nil {
		t.Fatalf("enqueue public: %v", err)
	}
	if err := q.Enqueue(selfRoute); err != nil {
		t.Fatalf("enqueue self-route: %v", err)
	}

	failed := q.FailQueuedRequestsForModel(model, nil)
	if failed != 1 {
		t.Fatalf("failed=%d, want 1 (only the public waiter)", failed)
	}
	// Public waiter received a nil (rejection).
	select {
	case p := <-public.ResponseCh:
		if p != nil {
			t.Fatal("public waiter should have received nil rejection")
		}
	default:
		t.Fatal("public waiter was not failed")
	}
	// Self-route waiter is still queued (not failed).
	if q.QueueSize(model) != 1 {
		t.Fatalf("queue size = %d, want 1 (self-route waiter must remain)", q.QueueSize(model))
	}
	select {
	case <-selfRoute.ResponseCh:
		t.Fatal("self-route waiter must NOT be failed by a public-unservable verdict")
	default:
	}
}

// TestCompetingQueueDepth pins the routing-compatibility filter behind the
// hedge governor's queued-demand input: only waiters that could drain onto
// capacity available to the probing request count.
func TestCompetingQueueDepth(t *testing.T) {
	q := NewRequestQueue(10, 30*time.Second)
	model := "queue-competing"

	add := func(id string, pending *PendingRequest) {
		t.Helper()
		if err := q.Enqueue(&QueuedRequest{
			RequestID:  id,
			Model:      model,
			ResponseCh: make(chan *Provider, 1),
			Pending:    pending,
		}); err != nil {
			t.Fatalf("enqueue %s: %v", id, err)
		}
	}
	add("pub", &PendingRequest{RequestID: "pub", Model: model})
	add("self", &PendingRequest{RequestID: "self", Model: model, SelfRouteOnly: true, OwnerAccountID: "acct-A"})
	add("pinned", &PendingRequest{RequestID: "pinned", Model: model, AllowedProviderSerials: []string{"SER-1"}})
	add("nilpending", nil)

	// Unconstrained request: the public waiter and the conservative
	// nil-Pending waiter compete; self-route and serial-pinned do not.
	public := &PendingRequest{RequestID: "probe", Model: model}
	if depth := q.CompetingQueueDepth(model, public); depth != 2 {
		t.Fatalf("public depth = %d, want 2 (pub + nil-Pending)", depth)
	}

	// Overlapping-pinned request: the pinned waiter now competes too.
	overlapping := &PendingRequest{RequestID: "probe-pin", Model: model, AllowedProviderSerials: []string{"SER-1", "SER-2"}}
	if depth := q.CompetingQueueDepth(model, overlapping); depth != 3 {
		t.Fatalf("overlapping-pinned depth = %d, want 3", depth)
	}

	// Disjoint-pinned request: back to 2 — the SER-1 waiter cannot use its pool.
	disjoint := &PendingRequest{RequestID: "probe-dis", Model: model, AllowedProviderSerials: []string{"SER-9"}}
	if depth := q.CompetingQueueDepth(model, disjoint); depth != 2 {
		t.Fatalf("disjoint-pinned depth = %d, want 2", depth)
	}

	// No constraint context (nil pr): only structural exclusions apply.
	if depth := q.CompetingQueueDepth(model, nil); depth != 2 {
		t.Fatalf("nil-pr depth = %d, want 2", depth)
	}

	// QueueSize stays the raw count.
	if q.QueueSize(model) != 4 {
		t.Fatalf("QueueSize = %d, want 4", q.QueueSize(model))
	}
}

// TestFailQueuedRequestsForModelSkipsEligiblePreferOwner verifies a prefer
// waiter whose owner HAS an owned provider for the model survives a
// public-unservable verdict (its own busy machine may free up).
func TestFailQueuedRequestsForModelSkipsEligiblePreferOwner(t *testing.T) {
	q := NewRequestQueue(10, 30*time.Second)
	model := "queue-prefer"

	public := &QueuedRequest{
		RequestID:  "pub",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending:    &PendingRequest{RequestID: "pub", Model: model},
	}
	prefer := &QueuedRequest{
		RequestID:  "prefer",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending:    &PendingRequest{RequestID: "prefer", Model: model, PreferOwner: true, OwnerAccountID: "acct-A"},
	}
	_ = q.Enqueue(public)
	_ = q.Enqueue(prefer)

	// PreferWaiterOwners surfaces the prefer owner so the caller can compute
	// eligibility; here acct-A has an owned provider for the model.
	owners := q.PreferWaiterOwners(model)
	if len(owners) != 1 || owners[0] != "acct-A" {
		t.Fatalf("PreferWaiterOwners = %v, want [acct-A]", owners)
	}
	eligible := map[string]bool{"acct-A": true}

	if failed := q.FailQueuedRequestsForModel(model, eligible); failed != 1 {
		t.Fatalf("failed=%d, want 1 (only the public waiter)", failed)
	}
	if q.QueueSize(model) != 1 {
		t.Fatalf("queue size = %d, want 1 (eligible prefer waiter must remain)", q.QueueSize(model))
	}
	select {
	case <-prefer.ResponseCh:
		t.Fatal("eligible prefer waiter must NOT be failed by a public-unservable verdict")
	default:
	}
}

// TestFailQueuedRequestsForModelFailsOwnerlessPreferWaiter verifies a prefer
// waiter whose owner has NO owned provider is failed fast (it's effectively a
// public request), not left to hit the 120s stale timeout.
func TestFailQueuedRequestsForModelFailsOwnerlessPreferWaiter(t *testing.T) {
	q := NewRequestQueue(10, 30*time.Second)
	model := "queue-prefer-noowner"

	prefer := &QueuedRequest{
		RequestID:  "prefer",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending:    &PendingRequest{RequestID: "prefer", Model: model, PreferOwner: true, OwnerAccountID: "acct-A"},
	}
	_ = q.Enqueue(prefer)

	// acct-A has no owned provider → not eligible → must be failed.
	if failed := q.FailQueuedRequestsForModel(model, map[string]bool{"acct-A": false}); failed != 1 {
		t.Fatalf("failed=%d, want 1 (owner-less prefer waiter must fail fast)", failed)
	}
	select {
	case p := <-prefer.ResponseCh:
		if p != nil {
			t.Fatal("owner-less prefer waiter should receive a nil rejection")
		}
	default:
		t.Fatal("owner-less prefer waiter was not failed")
	}
}
