package sandboxcontrol

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (c *Controller) HandleHostMessage(
	ctx context.Context,
	session *sandboxhost.Session,
	message protocol.SandboxDecodedMessage,
) error {
	switch payload := message.Payload.(type) {
	case *protocol.SandboxHostHeartbeatPayload:
		return c.handleHeartbeat(ctx, session, payload)
	case *protocol.SandboxOperationStatePayload:
		return c.handleOperationState(ctx, session, payload)
	case *protocol.SandboxCommandStatePayload:
		return c.handleCommandState(ctx, session, payload)
	case *protocol.SandboxHostFailurePayload:
		return c.handleHostFailure(ctx, session, payload)
	case *protocol.SandboxHostRegisterPayload:
		return nil
	default:
		return fmt.Errorf("unsupported sandbox host payload %T", payload)
	}
}

func (c *Controller) handleHeartbeat(
	ctx context.Context,
	session *sandboxhost.Session,
	heartbeat *protocol.SandboxHostHeartbeatPayload,
) error {
	c.scheduleMu.Lock()
	if heartbeat.NextFencingToken > c.hostNextFence[session.HostID()] {
		c.hostNextFence[session.HostID()] = heartbeat.NextFencingToken
	}
	c.scheduleMu.Unlock()

	if err := c.reconcileHost(ctx, session, heartbeat); err != nil {
		return err
	}
	sandboxes, err := c.store.ListActiveSandboxesByHost(
		ctx,
		session.HostID(),
	)
	if err != nil {
		return err
	}
	for index := range sandboxes {
		sandbox := &sandboxes[index]
		if err := c.driveTermination(ctx, sandbox); err != nil &&
			!IsConflict(err) &&
			!errors.Is(err, ErrHostUnavailable) {
			return err
		}
	}
	return nil
}

func (c *Controller) handleOperationState(
	ctx context.Context,
	session *sandboxhost.Session,
	payload *protocol.SandboxOperationStatePayload,
) error {
	sandbox, err := c.authorizeHostScope(ctx, session, payload.Scope)
	if err != nil {
		return err
	}
	operation, err := c.store.GetSandboxOperation(
		ctx,
		sandbox.AccountID,
		payload.OperationID,
	)
	if err != nil {
		return err
	}
	if operation.SandboxID != sandbox.ID ||
		operation.Kind != payload.Operation {
		return store.ErrSandboxConflict
	}
	var leaseExpiresAt *time.Time
	if operation.Kind == store.SandboxOperationKindRenew &&
		payload.State != protocol.SandboxOperationFailed {
		expiresAt := operation.RequestedLeaseExpiresAt
		leaseExpiresAt = &expiresAt
	}
	errorCode := ""
	if payload.ErrorCode != nil {
		errorCode = *payload.ErrorCode
	}
	updated, applied, err := c.store.ApplySandboxOperationUpdate(
		ctx,
		store.SandboxOperationUpdate{
			OperationID:    operation.ID,
			SandboxID:      sandbox.ID,
			Generation:     payload.Scope.Generation,
			FencingToken:   payload.Scope.FencingToken,
			State:          payload.State,
			ErrorCode:      errorCode,
			LeaseExpiresAt: leaseExpiresAt,
			UpdatedAt:      c.now().UTC(),
		},
	)
	if err != nil {
		return err
	}
	return c.continueSandboxOperation(ctx, updated, applied)
}

func (c *Controller) continueSandboxOperation(
	ctx context.Context,
	updated *store.SandboxRecord,
	applied *store.SandboxOperation,
) error {
	if applied.Kind == store.SandboxOperationKindPrepare &&
		applied.State == protocol.SandboxOperationFailed &&
		!updated.TerminationRequested {
		terminated, err := c.store.MarkSandboxTerminationRequested(
			ctx,
			updated.AccountID,
			updated.ID,
			applied.ID,
			c.now().UTC(),
		)
		if err != nil {
			return err
		}
		updated = terminated
	}
	if updated.TerminationRequested {
		if err := c.driveTermination(ctx, updated); err != nil &&
			!IsConflict(err) &&
			!errors.Is(err, ErrHostUnavailable) {
			return err
		}
	}
	return nil
}

func (c *Controller) handleCommandState(
	ctx context.Context,
	session *sandboxhost.Session,
	payload *protocol.SandboxCommandStatePayload,
) error {
	sandbox, err := c.authorizeHostScope(ctx, session, payload.Scope)
	if err != nil {
		return err
	}
	errorCode := ""
	if payload.ErrorCode != nil {
		errorCode = *payload.ErrorCode
	}
	command, err := c.store.ApplySandboxCommandUpdate(
		ctx,
		store.SandboxCommandUpdate{
			CommandID:       payload.CommandID,
			SandboxID:       sandbox.ID,
			Generation:      payload.Scope.Generation,
			FencingToken:    payload.Scope.FencingToken,
			State:           payload.State,
			ExitCode:        payload.ExitCode,
			StandardOutput:  payload.StandardOutput,
			StandardError:   payload.StandardError,
			OutputTruncated: payload.OutputTruncated,
			ErrorCode:       errorCode,
			UpdatedAt:       c.now().UTC(),
		},
	)
	if err != nil || !command.Terminal() {
		return err
	}
	pendingOperations, listErr := c.store.ListPendingSandboxOperationsByHost(
		ctx,
		session.HostID(),
	)
	if listErr != nil {
		return listErr
	}
	for index := range pendingOperations {
		pending := &pendingOperations[index]
		if pending.Sandbox.ID == sandbox.ID &&
			pending.Operation.Kind == store.SandboxOperationKindStop {
			_ = c.dispatchOperation(&pending.Sandbox, &pending.Operation)
		}
	}
	return err
}

func (c *Controller) handleHostFailure(
	ctx context.Context,
	session *sandboxhost.Session,
	payload *protocol.SandboxHostFailurePayload,
) error {
	if payload.Scope == nil {
		// Drain and other host-wide failures have no durable sandbox scope.
		return nil
	}
	sandbox, err := c.authorizeHostScope(ctx, session, *payload.Scope)
	if err != nil {
		return err
	}
	now := c.now().UTC()
	if payload.OperationID != nil {
		updated, applied, err := c.store.ApplySandboxOperationUpdate(
			ctx,
			store.SandboxOperationUpdate{
				OperationID:  *payload.OperationID,
				SandboxID:    sandbox.ID,
				Generation:   payload.Scope.Generation,
				FencingToken: payload.Scope.FencingToken,
				State:        store.SandboxOperationFailed,
				ErrorCode:    payload.ErrorCode,
				UpdatedAt:    now,
			},
		)
		if err != nil {
			return err
		}
		return c.continueSandboxOperation(ctx, updated, applied)
	}
	if payload.CommandID != nil {
		_, err := c.store.ApplySandboxCommandUpdate(
			ctx,
			store.SandboxCommandUpdate{
				CommandID:    *payload.CommandID,
				SandboxID:    sandbox.ID,
				Generation:   payload.Scope.Generation,
				FencingToken: payload.Scope.FencingToken,
				State:        store.SandboxCommandLost,
				ErrorCode:    payload.ErrorCode,
				UpdatedAt:    now,
			},
		)
		return err
	}
	return nil
}

func (c *Controller) authorizeHostScope(
	ctx context.Context,
	session *sandboxhost.Session,
	scope protocol.SandboxScope,
) (*store.SandboxRecord, error) {
	sandbox, err := c.store.GetSandboxByID(ctx, scope.SandboxID)
	if err != nil {
		return nil, err
	}
	if sandbox.HostID != session.HostID() ||
		sandbox.Generation != scope.Generation {
		return nil, store.ErrSandboxConflict
	}
	if scope.FencingToken != sandbox.FencingToken {
		// A renewal response is the sole legitimate authority advance. Its
		// operation transition performs the monotonic-token check.
		operationAdvance := scope.FencingToken > sandbox.FencingToken
		if !operationAdvance {
			return nil, store.ErrSandboxConflict
		}
	}
	return sandbox, nil
}
