package providerwrite

import (
	"context"
	"sync/atomic"
	"time"
)

// Writer ownership states are distinct from preparation metadata. Only
// InFlight, Completed and CanceledInFlight represent an authorized socket handoff.
const (
	providerWriteQueued int32 = iota
	providerWriteCanceledBeforeHandoff
	providerWriteBuilding
	providerWriteAwaitingOwner
	providerWriteInFlight
	providerWriteCompleted
	providerWriteRejected
	providerWriteAuthorizing
	providerWriteCanceledInFlight
)

// Metadata describes the writer-owned handoff of a deferred
// frame. The caller receives it synchronously and remains the sole owner of any
// request-state mutation derived from the handoff.
type Metadata struct {
	DequeuedAt time.Time
	// Committed is returned only after the owner acknowledged preparation and
	// any final authorization check succeeded. Preparation callbacks receive false.
	// A committed write can still fail or be canceled after socket handoff.
	Committed bool
}

// Builder constructs a data-lane frame only after it reaches the head
// of the provider writer queue. Builders must be fast, side-effect-free, and
// capture only immutable state. dequeuedAt is the writer's monotonic timestamp
// for budget calculations and subsequent caller-owned timing attribution.
type Builder func(dequeuedAt time.Time) ([]byte, error)

// Handoff runs synchronously on the submitting goroutine after the
// writer has built the frame and before it may expose bytes to the socket.
// It acknowledges preparation, not authorization or delivery. Publish dispatch
// accounting from the returned Metadata.Committed instead.
type Handoff func(Metadata)

type Request struct {
	ctx        context.Context
	data       []byte
	builder    Builder
	done       chan error
	handoff    chan Metadata
	handoffAck chan struct{}
	// beforeWrite is a fast authorization check after building and owner ack,
	// at the final handoff to the socket. It never holds locks across I/O.
	beforeWrite func() error
	// Written before publishing rejected state 6 and then immutable. The
	// result waiter reads it only after observing that atomic state.
	rejection error
	result    error
	// Uses the providerWrite* ownership states above.
	state atomic.Int32
}

// Publish notifies the submitting owner after execution recorded its result.
// Only the lane consumer may publish a request, exactly once.
func (r *Request) Publish() {
	if r.done != nil {
		r.done <- r.result
	}
}

func NewFrame(data []byte, authorize func() error) *Request {
	return &Request{ctx: context.Background(), data: append([]byte(nil), data...), beforeWrite: authorize, done: make(chan error, 1)}
}

func NewDeferred(builder Builder, authorize func() error) *Request {
	return &Request{ctx: context.Background(), builder: builder, beforeWrite: authorize, done: make(chan error, 1)}
}

func (r *Request) CanceledBeforeHandoff() bool {
	return r.state.Load() == providerWriteCanceledBeforeHandoff
}
