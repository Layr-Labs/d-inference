package requestqueue

import (
	"errors"
	"testing"
	"time"
)

// The queue operates on opaque payloads. These fixtures retain the existing
// FIFO/depth assertions without importing provider connections or routing.
type Provider struct{}
type QueuedRequest struct {
	RequestID, Model string
	ResponseCh       chan *Provider
	EnqueuedAt       time.Time
}
type fixtureQueue struct{ Queue[*QueuedRequest] }

var ErrQueueFull = ErrFull

func NewRequestQueue(size int, wait time.Duration) *fixtureQueue {
	return &fixtureQueue{Queue: New[*QueuedRequest](size, wait)}
}
func fixtureAccess() Access[*QueuedRequest] {
	return Access[*QueuedRequest]{
		Info: func(req *QueuedRequest) Info {
			return Info{ID: req.RequestID, Model: req.Model, EnqueuedAt: req.EnqueuedAt}
		},
		Prepare: func(req *QueuedRequest) {
			if req.ResponseCh == nil {
				req.ResponseCh = make(chan *Provider, 1)
			}
		},
		Enqueued: func(req *QueuedRequest, at time.Time, _ int) { req.EnqueuedAt = at },
		Expire: func(req *QueuedRequest) bool {
			select {
			case req.ResponseCh <- nil:
				return true
			default:
				return false
			}
		},
	}
}
func (q *fixtureQueue) Enqueue(req *QueuedRequest) error {
	return q.Queue.Enqueue(req, fixtureAccess())
}
func (q *fixtureQueue) Remove(id, model string) { q.Queue.Remove(id, model, fixtureAccess()) }

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
