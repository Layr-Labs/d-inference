package registry

import (
	"testing"
	"time"

	"github.com/dginf/coordinator/internal/protocol"
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
	for i := 0; i < 2; i++ {
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
	if err != ErrQueueFull {
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

	// TryAssign in a goroutine.
	go func() {
		time.Sleep(50 * time.Millisecond)
		assigned := q.TryAssign("test-model", provider)
		if !assigned {
			t.Error("TryAssign should have succeeded")
		}
	}()

	// WaitForProvider should succeed.
	p, err := q.WaitForProvider(req)
	if err != nil {
		t.Fatalf("WaitForProvider: %v", err)
	}
	if p == nil {
		t.Fatal("expected non-nil provider")
	}
	if p.ID != "p1" {
		t.Errorf("provider id = %q, want p1", p.ID)
	}
	if p.Status != StatusServing {
		t.Errorf("provider status = %q, want serving", p.Status)
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
	_, err := q.WaitForProvider(req)
	if err != ErrQueueTimeout {
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

func TestStaleRequestsCleanedUp(t *testing.T) {
	q := NewRequestQueue(10, 50*time.Millisecond)

	req := &QueuedRequest{
		RequestID:  "req-stale",
		Model:      "test-model",
		ResponseCh: make(chan *Provider, 1),
	}
	q.Enqueue(req)

	// Wait for the request to become stale.
	time.Sleep(100 * time.Millisecond)

	q.CleanStale()

	if q.QueueSize("test-model") != 0 {
		t.Errorf("queue size after clean = %d, want 0", q.QueueSize("test-model"))
	}
}

func TestTryAssignSkipsStaleRequests(t *testing.T) {
	q := NewRequestQueue(10, 50*time.Millisecond)

	// Enqueue a request.
	staleReq := &QueuedRequest{
		RequestID:  "req-stale",
		Model:      "test-model",
		ResponseCh: make(chan *Provider, 1),
	}
	q.Enqueue(staleReq)

	// Wait for it to become stale.
	time.Sleep(100 * time.Millisecond)

	// Enqueue a fresh request.
	freshReq := &QueuedRequest{
		RequestID:  "req-fresh",
		Model:      "test-model",
		ResponseCh: make(chan *Provider, 1),
	}
	q.Enqueue(freshReq)

	provider := &Provider{
		ID:     "p1",
		Status: StatusOnline,
	}

	// TryAssign should skip the stale one and assign to the fresh one.
	assigned := q.TryAssign("test-model", provider)
	if !assigned {
		t.Fatal("TryAssign should have succeeded for fresh request")
	}

	// Read the assigned provider.
	select {
	case p := <-freshReq.ResponseCh:
		if p.ID != "p1" {
			t.Errorf("provider id = %q, want p1", p.ID)
		}
	default:
		t.Error("fresh request should have received provider")
	}
}

func TestTryAssignNoQueuedRequests(t *testing.T) {
	q := NewRequestQueue(10, 30*time.Second)

	provider := &Provider{
		ID:     "p1",
		Status: StatusOnline,
	}

	assigned := q.TryAssign("test-model", provider)
	if assigned {
		t.Error("TryAssign should return false when queue is empty")
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
	if err := q.Enqueue(req3); err != ErrQueueFull {
		t.Errorf("expected ErrQueueFull for model-a, got %v", err)
	}
}
