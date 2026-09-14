package sandboxcontrol

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

var ErrStartUnavailable = errors.New("sandbox host does not support start")

// Start resumes the same allocation without extending it or creating another
// VM. Rotating its reserved fence prevents a queued stop from the previous run
// from acting after resume. Prior command idempotency records remain intact.
func (c *Controller) Start(ctx context.Context, accountID, sandboxID, idempotencyKey string) (*store.SandboxOperation, error) {
	if !protocol.ValidSandboxUUID(idempotencyKey) {
		return nil, ErrInvalidRequest
	}
	if existing, err := c.store.GetSandboxOperationByIdempotency(ctx, accountID, sandboxID, idempotencyKey); err == nil {
		if existing.Kind != store.SandboxOperationKindStart {
			return nil, ErrIdempotencyConflict
		}
		return existing, nil
	} else if !errors.Is(err, store.ErrNotFound) {
		return nil, err
	}
	sandbox, err := c.store.GetSandbox(ctx, accountID, sandboxID)
	if err != nil {
		return nil, err
	}
	now := c.now().UTC().Truncate(time.Millisecond)
	if sandbox.State != store.SandboxStateStopped || sandbox.TerminationRequested || !now.Before(sandbox.LeaseExpiresAt) {
		return nil, ErrSandboxNotReady
	}
	session, exists := c.hosts.Session(sandbox.HostID)
	if !exists {
		return nil, ErrHostUnavailable
	}
	if !session.Snapshot().Capabilities.SupportsStart {
		return nil, ErrStartUnavailable
	}
	operation := newSandboxOperation(sandbox, store.SandboxOperationKindStart, false, sandbox.LeaseExpiresAt, idempotencyKey, now)
	operation.RequestedFencingToken, err = c.nextFencingTokenForHost(sandbox.HostID, sandbox.FencingToken)
	if err != nil {
		return nil, err
	}
	updated, stored, created, err := c.store.BeginSandboxOperation(ctx, operation, store.SandboxStatePreparing)
	if err != nil {
		return nil, err
	}
	if !stored.SameRequest(operation) {
		return nil, ErrIdempotencyConflict
	}
	c.recordAllocatedFencingToken(updated.HostID, stored.RequestedFencingToken)
	if created {
		_ = c.dispatchOperation(updated, stored)
	}
	return stored, nil
}
