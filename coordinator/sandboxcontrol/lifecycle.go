package sandboxcontrol

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func (c *Controller) Execute(
	ctx context.Context,
	accountID string,
	sandboxID string,
	request CommandRequest,
) (*store.SandboxCommand, error) {
	sandbox, err := c.store.GetSandbox(ctx, accountID, sandboxID)
	if err != nil {
		return nil, err
	}
	if !protocol.ValidSandboxUUID(request.IdempotencyKey) {
		return nil, ErrInvalidRequest
	}
	if request.TimeoutSeconds == 0 {
		request.TimeoutSeconds = CommandTimeoutSeconds
	}
	if len(request.Environment) == 0 {
		request.Environment = nil
	}
	var workingDirectory *string
	if request.WorkingDirectory != "" {
		workingDirectory = &request.WorkingDirectory
	}
	commandID := uuid.NewString()
	payload := protocol.SandboxCommandPayload{
		CommandID:        commandID,
		IdempotencyKey:   request.IdempotencyKey,
		Scope:            sandboxScope(sandbox),
		Arguments:        append([]string(nil), request.Arguments...),
		Environment:      cloneEnvironment(request.Environment),
		WorkingDirectory: workingDirectory,
		TimeoutSeconds:   request.TimeoutSeconds,
	}
	if err := protocol.ValidateSandboxCommand(&payload); err != nil {
		return nil, ErrInvalidRequest
	}
	now := c.now().UTC().Truncate(time.Millisecond)
	command := &store.SandboxCommand{
		ID:               commandID,
		SandboxID:        sandbox.ID,
		AccountID:        sandbox.AccountID,
		IdempotencyKey:   request.IdempotencyKey,
		Generation:       sandbox.Generation,
		FencingToken:     sandbox.FencingToken,
		Arguments:        append([]string(nil), request.Arguments...),
		Environment:      cloneEnvironment(request.Environment),
		WorkingDirectory: request.WorkingDirectory,
		TimeoutSeconds:   request.TimeoutSeconds,
		State:            store.SandboxCommandPending,
		CreatedAt:        now,
		UpdatedAt:        now,
	}
	stored, created, err := c.store.CreateSandboxCommand(ctx, command)
	if err != nil {
		return nil, err
	}
	if !stored.SameRequest(command) {
		return nil, ErrIdempotencyConflict
	}
	if !created &&
		(stored.Terminal() ||
			sandbox.State != store.SandboxStateReady ||
			sandbox.TerminationRequested ||
			sandbox.Generation != stored.Generation ||
			sandbox.FencingToken != stored.FencingToken) {
		return stored, nil
	}
	_ = c.dispatchCommand(sandbox, stored)
	return stored, nil
}

func (c *Controller) Renew(
	ctx context.Context,
	accountID string,
	sandboxID string,
	idempotencyKey string,
) (*store.SandboxOperation, error) {
	if !protocol.ValidSandboxUUID(idempotencyKey) {
		return nil, ErrInvalidRequest
	}
	if existing, err := c.store.GetSandboxOperationByIdempotency(
		ctx,
		accountID,
		sandboxID,
		idempotencyKey,
	); err == nil {
		if existing.Kind != store.SandboxOperationKindRenew {
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
	if sandbox.State != store.SandboxStateReady &&
		sandbox.State != store.SandboxStateStopped {
		return nil, ErrSandboxNotReady
	}
	if sandbox.TerminationRequested {
		return nil, store.ErrSandboxConflict
	}
	now := c.now().UTC().Truncate(time.Millisecond)
	expiresAt := now.Add(LeaseDuration)
	operation := newSandboxOperation(
		sandbox,
		store.SandboxOperationKindRenew,
		false,
		expiresAt,
		idempotencyKey,
		now,
	)
	requestedFencingToken, err := c.nextFencingTokenForHost(
		sandbox.HostID,
		sandbox.FencingToken,
	)
	if err != nil {
		return nil, err
	}
	operation.RequestedFencingToken = requestedFencingToken
	updatedSandbox, stored, created, err := c.store.BeginSandboxOperation(
		ctx,
		operation,
		sandbox.State,
	)
	if err != nil {
		return nil, err
	}
	if !stored.SameRequest(operation) {
		return nil, ErrIdempotencyConflict
	}
	c.recordAllocatedFencingToken(
		updatedSandbox.HostID,
		stored.RequestedFencingToken,
	)
	if created {
		_ = c.dispatchOperation(updatedSandbox, stored)
	}
	return stored, nil
}

func (c *Controller) nextFencingTokenForHost(
	hostID string,
	current uint64,
) (uint64, error) {
	if current >= maximumCoordinatorFencingToken {
		return 0, store.ErrSandboxConflict
	}
	c.scheduleMu.Lock()
	defer c.scheduleMu.Unlock()
	next := current + 1
	if local := c.hostNextFence[hostID]; local > next {
		next = local
	}
	if session, exists := c.hosts.Session(hostID); exists {
		snapshot := session.Snapshot()
		if snapshot.Heartbeat != nil &&
			snapshot.Heartbeat.NextFencingToken > next {
			next = snapshot.Heartbeat.NextFencingToken
		}
	}
	if next == 0 || next > maximumCoordinatorFencingToken {
		return 0, store.ErrSandboxConflict
	}
	return next, nil
}

func (c *Controller) recordAllocatedFencingToken(
	hostID string,
	issued uint64,
) {
	if issued == 0 || issued >= maximumCoordinatorFencingToken {
		return
	}
	c.scheduleMu.Lock()
	if next := issued + 1; next > c.hostNextFence[hostID] {
		c.hostNextFence[hostID] = next
	}
	c.scheduleMu.Unlock()
}

func (c *Controller) Stop(
	ctx context.Context,
	accountID string,
	sandboxID string,
	idempotencyKey string,
) (*store.SandboxOperation, error) {
	if !protocol.ValidSandboxUUID(idempotencyKey) {
		return nil, ErrInvalidRequest
	}
	if existing, err := c.store.GetSandboxOperationByIdempotency(
		ctx,
		accountID,
		sandboxID,
		idempotencyKey,
	); err == nil {
		if existing.Kind != store.SandboxOperationKindStop ||
			existing.DeleteAfterStop {
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
	return c.beginStop(ctx, sandbox, false, idempotencyKey)
}

func (c *Controller) Terminate(
	ctx context.Context,
	accountID string,
	sandboxID string,
	idempotencyKey string,
) (*store.SandboxOperation, error) {
	if !protocol.ValidSandboxUUID(idempotencyKey) {
		return nil, ErrInvalidRequest
	}
	if existing, err := c.store.GetSandboxOperationByIdempotency(
		ctx,
		accountID,
		sandboxID,
		idempotencyKey,
	); err == nil {
		if (existing.Kind != store.SandboxOperationKindStop ||
			!existing.DeleteAfterStop) &&
			existing.Kind != store.SandboxOperationKindDelete {
			return nil, ErrIdempotencyConflict
		}
		return existing, nil
	} else if !errors.Is(err, store.ErrNotFound) {
		return nil, err
	}
	sandbox, err := c.store.MarkSandboxTerminationRequested(
		ctx,
		accountID,
		sandboxID,
		idempotencyKey,
		c.now().UTC(),
	)
	if err != nil {
		return nil, err
	}
	switch sandbox.State {
	case store.SandboxStateReady:
		return c.beginTerminationStage(
			ctx,
			sandbox,
			store.SandboxOperationKindStop,
		)
	case store.SandboxStateStopped, store.SandboxStateFailed:
		return c.beginTerminationStage(
			ctx,
			sandbox,
			store.SandboxOperationKindDelete,
		)
	case store.SandboxStateDeleted:
		return c.beginTerminationStage(
			ctx,
			sandbox,
			store.SandboxOperationKindDelete,
		)
	case store.SandboxStatePreparing,
		store.SandboxStateStopping,
		store.SandboxStateDeleting:
		return c.pendingTerminationOperation(ctx, sandbox)
	default:
		return nil, ErrSandboxNotReady
	}
}

func (c *Controller) beginStop(
	ctx context.Context,
	sandbox *store.SandboxRecord,
	deleteAfterStop bool,
	idempotencyKey string,
) (*store.SandboxOperation, error) {
	if sandbox.State != store.SandboxStateReady {
		return nil, ErrSandboxNotReady
	}
	now := c.now().UTC()
	operation := newSandboxOperation(
		sandbox,
		store.SandboxOperationKindStop,
		deleteAfterStop,
		time.Time{},
		idempotencyKey,
		now,
	)
	updatedSandbox, stored, created, err := c.store.BeginSandboxOperation(
		ctx,
		operation,
		store.SandboxStateStopping,
	)
	if err != nil {
		return nil, err
	}
	if !stored.SameRequest(operation) {
		return nil, ErrIdempotencyConflict
	}
	if created {
		if stored.State == store.SandboxOperationQueued {
			_ = c.dispatchSandboxCommandCancellations(ctx, updatedSandbox)
		} else {
			_ = c.dispatchOperation(updatedSandbox, stored)
		}
	}
	return stored, nil
}

func (c *Controller) beginDelete(
	ctx context.Context,
	sandbox *store.SandboxRecord,
	idempotencyKey string,
) (*store.SandboxOperation, error) {
	if sandbox.State != store.SandboxStateStopped &&
		sandbox.State != store.SandboxStateFailed {
		return nil, ErrSandboxNotReady
	}
	now := c.now().UTC()
	operation := newSandboxOperation(
		sandbox,
		store.SandboxOperationKindDelete,
		false,
		time.Time{},
		idempotencyKey,
		now,
	)
	updatedSandbox, stored, created, err := c.store.BeginSandboxOperation(
		ctx,
		operation,
		store.SandboxStateDeleting,
	)
	if err != nil {
		return nil, err
	}
	if !stored.SameRequest(operation) {
		return nil, ErrIdempotencyConflict
	}
	if created {
		_ = c.dispatchOperation(updatedSandbox, stored)
	}
	return stored, nil
}

func newSandboxOperation(
	sandbox *store.SandboxRecord,
	kind string,
	deleteAfterStop bool,
	expiresAt time.Time,
	idempotencyKey string,
	now time.Time,
) *store.SandboxOperation {
	return &store.SandboxOperation{
		ID:                      uuid.NewString(),
		SandboxID:               sandbox.ID,
		AccountID:               sandbox.AccountID,
		IdempotencyKey:          idempotencyKey,
		Kind:                    kind,
		State:                   store.SandboxOperationPending,
		Generation:              sandbox.Generation,
		FencingToken:            sandbox.FencingToken,
		PreviousSandboxState:    sandbox.State,
		DeleteAfterStop:         deleteAfterStop,
		RequestedLeaseExpiresAt: expiresAt,
		CreatedAt:               now,
		UpdatedAt:               now,
	}
}

func cloneEnvironment(environment map[string]string) map[string]string {
	if environment == nil {
		return nil
	}
	cloned := make(map[string]string, len(environment))
	for key, value := range environment {
		cloned[key] = value
	}
	return cloned
}

func IsConflict(err error) bool {
	return errors.Is(err, store.ErrSandboxConflict) ||
		errors.Is(err, store.ErrSandboxInvalidTransition) ||
		errors.Is(err, ErrSandboxNotReady) ||
		errors.Is(err, ErrIdempotencyConflict)
}
