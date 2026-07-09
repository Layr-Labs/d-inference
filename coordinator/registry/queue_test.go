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
	if q.maxWait != 120*time.Second {
		t.Fatalf("maxWait = %v, want default 120s", q.maxWait)
	}
}

func TestNewRequestQueueFromEnvOverrides(t *testing.T) {
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_DEPTH", "7")
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_WAIT", "45s")

	q := NewRequestQueueFromEnv()
	if q.MaxSize() != 7 {
		t.Fatalf("MaxSize() = %d, want 7", q.MaxSize())
	}
	if q.maxWait != 45*time.Second {
		t.Fatalf("maxWait = %v, want 45s", q.maxWait)
	}
}

func TestNewRequestQueueFromEnvRejectsInvalidValues(t *testing.T) {
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_DEPTH", "0")
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_WAIT", "-5s")

	q := NewRequestQueueFromEnv()
	if q.MaxSize() != 32 {
		t.Fatalf("MaxSize() = %d, want default 32 for non-positive depth", q.MaxSize())
	}
	if q.maxWait != 120*time.Second {
		t.Fatalf("maxWait = %v, want default 120s for non-positive wait", q.maxWait)
	}

	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_DEPTH", "not-a-number")
	t.Setenv(env.EnvPrefix+"_QUEUE_MAX_WAIT", "soon")
	q = NewRequestQueueFromEnv()
	if q.MaxSize() != 32 || q.maxWait != 120*time.Second {
		t.Fatalf("malformed env -> (%d, %v), want defaults (32, 120s)", q.MaxSize(), q.maxWait)
	}
}

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

func TestRequestQueueShedSnapshotGuardsLateEnqueue(t *testing.T) {
	q := NewRequestQueue(10, 30*time.Second)
	build := "queue-shed-build"
	alias := "queue-shed-alias"
	q.ReplaceShedModels([]string{alias})

	matching := &QueuedRequest{
		RequestID: "matching",
		Model:     build,
		Pending:   &PendingRequest{RequestID: "matching", Model: build, PublicModel: alias},
	}
	if err := q.Enqueue(matching); !errors.Is(err, ErrModelShed) {
		t.Fatalf("matching alias enqueue error = %v, want ErrModelShed", err)
	}

	raw := &QueuedRequest{
		RequestID: "raw",
		Model:     build,
		Pending:   &PendingRequest{RequestID: "raw", Model: build, PublicModel: build},
	}
	if err := q.Enqueue(raw); err != nil {
		t.Fatalf("raw-build waiter sharing the concrete queue was rejected: %v", err)
	}

	selfRoute := &QueuedRequest{
		RequestID: "self",
		Model:     build,
		Pending:   &PendingRequest{RequestID: "self", Model: build, PublicModel: alias, SelfRouteOnly: true},
	}
	if err := q.Enqueue(selfRoute); err != nil {
		t.Fatalf("exclusive self-route waiter was rejected: %v", err)
	}
	if got := q.QueueSize(build); got != 2 {
		t.Fatalf("queue size = %d, want raw-build plus self-route waiters", got)
	}
}

func TestRequestQueueShedSnapshotGuardsRequeueAndDrainAssignment(t *testing.T) {
	q := NewRequestQueue(10, 30*time.Second)
	model := "queue-shed-model"

	requeued := &QueuedRequest{
		RequestID: "requeued",
		Model:     model,
		Pending:   &PendingRequest{RequestID: "requeued", Model: model, PublicModel: model},
	}
	draining := &QueuedRequest{
		RequestID: "draining",
		Model:     model,
		Pending:   &PendingRequest{RequestID: "draining", Model: model, PublicModel: model},
	}
	if err := q.Enqueue(requeued); err != nil {
		t.Fatalf("enqueue requeue candidate: %v", err)
	}
	if err := q.Enqueue(draining); err != nil {
		t.Fatalf("enqueue drain candidate: %v", err)
	}
	requeued = q.PopNextFresh(model)
	draining = q.PopNextFresh(model)
	q.ReplaceShedModels([]string{model})
	q.RequeueFront(requeued)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := q.WaitForProviderContext(ctx, requeued); !errors.Is(err, ErrModelShed) {
		t.Fatalf("requeued shed waiter error = %v, want ErrModelShed", err)
	}

	if q.AssignProviderIfAllowed(draining, &Provider{ID: "p1"}) {
		t.Fatal("drain assigned a provider after the model was shed")
	}
	if _, err := q.WaitForProviderContext(ctx, draining); !errors.Is(err, ErrModelShed) {
		t.Fatalf("draining shed waiter error = %v, want ErrModelShed", err)
	}

	// Exclusive self-route bypasses the public shed even if it was popped before
	// the replacement and reaches the final assignment afterward.
	q.ReplaceShedModels(nil)
	selfRoute := &QueuedRequest{
		RequestID: "self",
		Model:     model,
		Pending:   &PendingRequest{RequestID: "self", Model: model, PublicModel: model, SelfRouteOnly: true},
	}
	if err := q.Enqueue(selfRoute); err != nil {
		t.Fatalf("enqueue self-route: %v", err)
	}
	selfRoute = q.PopNextFresh(model)
	q.ReplaceShedModels([]string{model})
	provider := &Provider{ID: "self-provider"}
	if !q.AssignProviderIfAllowed(selfRoute, provider) {
		t.Fatal("self-route drain was blocked by the public shed")
	}
	if got, err := q.WaitForProviderContext(ctx, selfRoute); err != nil || got != provider {
		t.Fatalf("self-route assignment = (%v, %v), want provider", got, err)
	}
}

func TestRequestQueueAssignmentAndAbandonAreAtomic(t *testing.T) {
	q := NewRequestQueue(10, 30*time.Second)
	for i := 0; i < 1000; i++ {
		req := &QueuedRequest{
			RequestID: "atomic",
			Model:     "atomic-model",
			Pending:   &PendingRequest{RequestID: "atomic", Model: "atomic-model"},
		}
		req.init()
		provider := &Provider{ID: "p1"}
		start := make(chan struct{})
		assignedCh := make(chan bool, 1)
		abandonedCh := make(chan bool, 1)
		go func() {
			<-start
			assignedCh <- q.AssignProviderIfAllowed(req, provider)
		}()
		go func() {
			<-start
			abandonedCh <- q.abandonIfWaiting(req)
		}()
		close(start)
		assigned := <-assignedCh
		abandoned := <-abandonedCh
		if assigned == abandoned {
			t.Fatalf("iteration %d: assigned=%v abandoned=%v, want exactly one terminal transition", i, assigned, abandoned)
		}
		if assigned {
			select {
			case got := <-req.ResponseCh:
				if got != provider {
					t.Fatalf("iteration %d: assigned provider = %v, want %v", i, got, provider)
				}
			default:
				t.Fatalf("iteration %d: assignment won without provider response", i)
			}
		} else {
			select {
			case <-req.Done():
			default:
				t.Fatalf("iteration %d: abandon won without closing Done", i)
			}
		}
	}
}
