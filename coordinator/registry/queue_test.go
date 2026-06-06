package registry

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestEnqueueAndSize(t *testing.T) {
	q := NewRequestQueue(10, 30*time.Second)

	req := &QueuedRequest{
		RequestID:  "req-1",
		Model:      "test-model",
		ResponseCh: make(chan *Provider, 1),
	}

	if err := q.Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	if q.QueueSize("test-model") != 1 {
		t.Errorf("queue size = %d, want 1", q.QueueSize("test-model"))
	}
	if q.TotalSize() != 1 {
		t.Errorf("total size = %d, want 1", q.TotalSize())
	}
}

func TestQueueMaxSizeEnforced(t *testing.T) {
	q := NewRequestQueue(2, 30*time.Second)

	// Fill the queue.
	for i := range 2 {
		req := &QueuedRequest{
			RequestID:  "req-" + string(rune('0'+i)),
			Model:      "test-model",
			ResponseCh: make(chan *Provider, 1),
		}
		if err := q.Enqueue(req); err != nil {
			t.Fatalf("enqueue %d: %v", i, err)
		}
	}

	// Third enqueue should fail.
	req := &QueuedRequest{
		RequestID:  "req-overflow",
		Model:      "test-model",
		ResponseCh: make(chan *Provider, 1),
	}
	err := q.Enqueue(req)
	if !errors.Is(err, ErrQueueFull) {
		t.Errorf("expected ErrQueueFull, got %v", err)
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

func TestQueueRemove(t *testing.T) {
	q := NewRequestQueue(10, 30*time.Second)

	req := &QueuedRequest{
		RequestID:  "req-1",
		Model:      "test-model",
		ResponseCh: make(chan *Provider, 1),
	}
	q.Enqueue(req)

	q.Remove("req-1", "test-model")

	if q.QueueSize("test-model") != 0 {
		t.Errorf("queue size after remove = %d, want 0", q.QueueSize("test-model"))
	}
}

func TestMultipleModelsQueues(t *testing.T) {
	q := NewRequestQueue(10, 30*time.Second)

	req1 := &QueuedRequest{
		RequestID:  "req-1",
		Model:      "model-a",
		ResponseCh: make(chan *Provider, 1),
	}
	req2 := &QueuedRequest{
		RequestID:  "req-2",
		Model:      "model-b",
		ResponseCh: make(chan *Provider, 1),
	}

	q.Enqueue(req1)
	q.Enqueue(req2)

	if q.QueueSize("model-a") != 1 {
		t.Errorf("model-a queue size = %d, want 1", q.QueueSize("model-a"))
	}
	if q.QueueSize("model-b") != 1 {
		t.Errorf("model-b queue size = %d, want 1", q.QueueSize("model-b"))
	}
	if q.TotalSize() != 2 {
		t.Errorf("total size = %d, want 2", q.TotalSize())
	}
}

func TestQueueDifferentModelsMaxSize(t *testing.T) {
	q := NewRequestQueue(1, 30*time.Second)

	// Each model gets its own queue with maxSize.
	req1 := &QueuedRequest{
		RequestID:  "req-1",
		Model:      "model-a",
		ResponseCh: make(chan *Provider, 1),
	}
	req2 := &QueuedRequest{
		RequestID:  "req-2",
		Model:      "model-b",
		ResponseCh: make(chan *Provider, 1),
	}

	if err := q.Enqueue(req1); err != nil {
		t.Fatalf("enqueue model-a: %v", err)
	}
	if err := q.Enqueue(req2); err != nil {
		t.Fatalf("enqueue model-b: %v", err)
	}

	// model-a queue is full.
	req3 := &QueuedRequest{
		RequestID:  "req-3",
		Model:      "model-a",
		ResponseCh: make(chan *Provider, 1),
	}
	if err := q.Enqueue(req3); !errors.Is(err, ErrQueueFull) {
		t.Errorf("expected ErrQueueFull for model-a, got %v", err)
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
