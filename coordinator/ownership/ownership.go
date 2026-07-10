// Package ownership implements the single-active coordinator fencing epoch
// shared by the rollback-safe Go baseline and the Rust coordinator (plan §20).
//
// Milestone 0.7 scaffolding: the API is defined and unit-tested. Production
// wiring (PostgreSQL advisory lock + rust_coord.coordinator_ownership CAS)
// lands before Milestone 4 paid pilot shares the database.
package ownership

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
)

// ErrOwnershipLost means this process no longer holds the active epoch.
var ErrOwnershipLost = errors.New("coordinator ownership lost")

// ErrUnsafeStartup means Rust durable jobs/leases remain active and this Go
// binary must refuse to admit new work (unless recovery mode).
var ErrUnsafeStartup = errors.New("unsafe startup: active rust_coord jobs or leases")

// Epoch is a monotonically increasing coordinator fencing token.
type Epoch uint64

// Gate is the process-local view of coordinator ownership.
type Gate struct {
	mu           sync.Mutex
	epoch        atomic.Uint64
	holding      atomic.Bool
	recoveryMode bool
	refuseOnRust bool
	rustActive   bool // set by startup probe against rust_coord.* tables
}

// NewGate constructs an ownership gate. refuseOnRust should be true for the
// rollback-safe Go image once Rust schema objects may exist.
func NewGate(refuseOnRust bool) *Gate {
	return &Gate{refuseOnRust: refuseOnRust}
}

// SetRustActive records whether the startup probe found active Rust jobs,
// prepared leases, or review_pending rows.
func (g *Gate) SetRustActive(active bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.rustActive = active
}

// EnableRecoveryMode allows a recovery-only process to settle/release Rust
// jobs without admitting new consumer traffic.
func (g *Gate) EnableRecoveryMode() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.recoveryMode = true
}

// Acquire records that this process now holds fencingEpoch. Callers must
// obtain the PostgreSQL lock/lease in the same transaction that bumps the
// durable epoch before calling Acquire.
func (g *Gate) Acquire(fencingEpoch Epoch) error {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.refuseOnRust && g.rustActive && !g.recoveryMode {
		return ErrUnsafeStartup
	}
	g.epoch.Store(uint64(fencingEpoch))
	g.holding.Store(true)
	return nil
}

// Release drops local ownership. The durable epoch release must be the final
// mutating action before process exit (plan §25/§26).
func (g *Gate) Release() {
	g.holding.Store(false)
}

// Holding reports whether this process currently believes it owns admission.
func (g *Gate) Holding() bool {
	return g.holding.Load()
}

// Epoch returns the fencing epoch this process acquired, or 0 if none.
func (g *Gate) Epoch() Epoch {
	return Epoch(g.epoch.Load())
}

// AssertHolding returns ErrOwnershipLost when admission must stop.
func (g *Gate) AssertHolding() error {
	if !g.Holding() {
		return ErrOwnershipLost
	}
	return nil
}

// CheckStartup is the refuse-unsafe-startup gate used by main before routes open.
func (g *Gate) CheckStartup(ctx context.Context) error {
	_ = ctx
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.refuseOnRust && g.rustActive && !g.recoveryMode {
		return ErrUnsafeStartup
	}
	return nil
}
