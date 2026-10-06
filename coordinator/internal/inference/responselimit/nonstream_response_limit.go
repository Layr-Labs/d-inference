// Package responselimit bounds the provider output a non-streaming attempt may
// retain. Provider ingress and response assembly each account their own budget.
package responselimit

import "github.com/eigeninference/d-inference/coordinator/registry"

// These are wire-payload limits, not token estimates. JSON envelopes, reasoning,
// tool arguments and usage all consume bytes; empty frames still consume slots.
const (
	DefaultMaxBytes  = 64 << 20
	DefaultMaxChunks = 262144
)

// Limits are the deployment's ceilings for one attempt. Non-positive values
// retain the safe defaults; limits cannot be disabled.
type Limits struct {
	MaxBytes  int
	MaxChunks int
}

// NewBudget returns one attempt's budget. Streaming attempts keep the existing
// backpressure policy and receive none.
func (l Limits) NewBudget(stream bool) *registry.ResponseBudget {
	if stream {
		return nil
	}
	bytes, chunks := l.MaxBytes, l.MaxChunks
	if bytes <= 0 {
		bytes = DefaultMaxBytes
	}
	if chunks <= 0 {
		chunks = DefaultMaxChunks
	}
	return registry.NewResponseBudget(bytes, chunks)
}
