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
	if sandbox.State != store.SandboxStateReady {
		return nil, ErrSandboxNotReady
	}
	if request.IdempotencyKey == "" {
		request.IdempotencyKey = uuid.NewString()
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
	now := c.now().UTC()
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
	if !created && stored.Terminal() {
		return stored, nil
	}
	session, exists := c.hosts.Session(sandbox.HostID)
	if !exists {
		if created {
			c.failCommandDispatch(ctx, stored, "host_unavailable")
		}
		return nil, ErrHostUnavailable
	}
	payload.CommandID = stored.ID
	if err := session.Send(ctx, protocol.SandboxTypeCommand, payload); err != nil {
		if created {
			c.failCommandDispatch(ctx, stored, "host_unavailable")
		}
		return nil, ErrHostUnavailable
	}
	return stored, nil
}

func (c *Controller) Renew(
	ctx context.Context,
	accountID string,
	sandboxID string,
) (*store.SandboxOperation, error) {
	sandbox, err := c.store.GetSandbox(ctx, accountID, sandboxID)
	if err != nil {
		return nil, err
	}
	if sandbox.State != store.SandboxStateReady &&
		sandbox.State != store.SandboxStateStopped {
		return nil, ErrSandboxNotReady
	}
	now := c.now().UTC()
	expiresAt := now.Add(LeaseDuration)
	operation := newSandboxOperation(
		sandbox,
		store.SandboxOperationKindRenew,
		false,
		expiresAt,
		now,
	)
	if _, err := c.store.BeginSandboxOperation(
		ctx,
		operation,
		sandbox.State,
	); err != nil {
		return nil, err
	}
	session, exists := c.hosts.Session(sandbox.HostID)
	if !exists {
		c.failOperationDispatch(ctx, sandbox, operation, "host_unavailable")
		return nil, ErrHostUnavailable
	}
	payload := protocol.SandboxLeaseRenewPayload{
		OperationID:    operation.ID,
		Scope:          sandboxScope(sandbox),
		LeaseExpiresAt: expiresAt.Format(time.RFC3339Nano),
	}
	if err := session.Send(
		ctx,
		protocol.SandboxTypeLeaseRenew,
		payload,
	); err != nil {
		c.failOperationDispatch(ctx, sandbox, operation, "host_unavailable")
		return nil, ErrHostUnavailable
	}
	return operation, nil
}

func (c *Controller) Stop(
	ctx context.Context,
	accountID string,
	sandboxID string,
) (*store.SandboxOperation, error) {
	sandbox, err := c.store.GetSandbox(ctx, accountID, sandboxID)
	if err != nil {
		return nil, err
	}
	return c.beginStop(ctx, sandbox, false)
}

func (c *Controller) Terminate(
	ctx context.Context,
	accountID string,
	sandboxID string,
) (*store.SandboxOperation, error) {
	sandbox, err := c.store.GetSandbox(ctx, accountID, sandboxID)
	if err != nil {
		return nil, err
	}
	switch sandbox.State {
	case store.SandboxStateReady:
		return c.beginStop(ctx, sandbox, true)
	case store.SandboxStateStopped, store.SandboxStateFailed:
		return c.beginDelete(ctx, sandbox)
	case store.SandboxStateDeleted:
		return nil, store.ErrSandboxConflict
	default:
		return nil, ErrSandboxNotReady
	}
}

func (c *Controller) beginStop(
	ctx context.Context,
	sandbox *store.SandboxRecord,
	deleteAfterStop bool,
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
		now,
	)
	if _, err := c.store.BeginSandboxOperation(
		ctx,
		operation,
		store.SandboxStateStopping,
	); err != nil {
		return nil, err
	}
	session, exists := c.hosts.Session(sandbox.HostID)
	if !exists {
		c.failOperationDispatch(ctx, sandbox, operation, "host_unavailable")
		return nil, ErrHostUnavailable
	}
	if err := session.Send(
		ctx,
		protocol.SandboxTypeStop,
		protocol.SandboxOperationPayload{
			OperationID: operation.ID,
			Scope:       sandboxScope(sandbox),
		},
	); err != nil {
		c.failOperationDispatch(ctx, sandbox, operation, "host_unavailable")
		return nil, ErrHostUnavailable
	}
	return operation, nil
}

func (c *Controller) beginDelete(
	ctx context.Context,
	sandbox *store.SandboxRecord,
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
		now,
	)
	if _, err := c.store.BeginSandboxOperation(
		ctx,
		operation,
		store.SandboxStateDeleting,
	); err != nil {
		return nil, err
	}
	session, exists := c.hosts.Session(sandbox.HostID)
	if !exists {
		c.failOperationDispatch(ctx, sandbox, operation, "host_unavailable")
		return nil, ErrHostUnavailable
	}
	if err := session.Send(
		ctx,
		protocol.SandboxTypeDelete,
		protocol.SandboxOperationPayload{
			OperationID: operation.ID,
			Scope:       sandboxScope(sandbox),
		},
	); err != nil {
		c.failOperationDispatch(ctx, sandbox, operation, "host_unavailable")
		return nil, ErrHostUnavailable
	}
	return operation, nil
}

func newSandboxOperation(
	sandbox *store.SandboxRecord,
	kind string,
	deleteAfterStop bool,
	expiresAt time.Time,
	now time.Time,
) *store.SandboxOperation {
	return &store.SandboxOperation{
		ID:                      uuid.NewString(),
		SandboxID:               sandbox.ID,
		AccountID:               sandbox.AccountID,
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

func (c *Controller) failCommandDispatch(
	ctx context.Context,
	command *store.SandboxCommand,
	errorCode string,
) {
	now := c.now().UTC()
	_, _ = c.store.ApplySandboxCommandUpdate(
		ctx,
		store.SandboxCommandUpdate{
			CommandID:    command.ID,
			SandboxID:    command.SandboxID,
			Generation:   command.Generation,
			FencingToken: command.FencingToken,
			State:        store.SandboxCommandLost,
			ErrorCode:    errorCode,
			UpdatedAt:    now,
		},
	)
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
