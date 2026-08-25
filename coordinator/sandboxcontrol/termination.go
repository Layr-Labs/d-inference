package sandboxcontrol

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

const maximumTerminationStageAttempts = store.MaxSandboxListLimit

func (c *Controller) driveTermination(
	ctx context.Context,
	sandbox *store.SandboxRecord,
) error {
	if sandbox == nil || !sandbox.TerminationRequested {
		return nil
	}
	switch sandbox.State {
	case store.SandboxStateReady:
		_, err := c.beginTerminationStage(
			ctx,
			sandbox,
			store.SandboxOperationKindStop,
		)
		return err
	case store.SandboxStateStopped, store.SandboxStateFailed:
		_, err := c.beginTerminationStage(
			ctx,
			sandbox,
			store.SandboxOperationKindDelete,
		)
		return err
	default:
		return nil
	}
}

func (c *Controller) beginTerminationStage(
	ctx context.Context,
	sandbox *store.SandboxRecord,
	kind string,
) (*store.SandboxOperation, error) {
	if sandbox == nil ||
		!sandbox.TerminationRequested ||
		!protocolTerminationStage(kind) {
		return nil, store.ErrSandboxConflict
	}
	idempotencyKey, err := terminationStageKey(
		sandbox.TerminationIdempotencyKey,
		kind,
	)
	if err != nil {
		return nil, err
	}
	for attempt := 0; attempt < maximumTerminationStageAttempts; attempt++ {
		existing, getErr := c.store.GetSandboxOperationByIdempotency(
			ctx,
			sandbox.AccountID,
			sandbox.ID,
			idempotencyKey,
		)
		switch {
		case getErr == nil:
			if !matchingTerminationStage(existing, kind) {
				return nil, ErrIdempotencyConflict
			}
			if !existing.Terminal() ||
				existing.State != store.SandboxOperationFailed ||
				!terminationRetryDue(
					existing.UpdatedAt,
					c.now().UTC(),
				) {
				return existing, nil
			}
			idempotencyKey, err = terminationRetryKey(existing.ID)
			if err != nil {
				return nil, err
			}
			continue
		case !errors.Is(getErr, store.ErrNotFound):
			return nil, getErr
		}

		var operation *store.SandboxOperation
		switch kind {
		case store.SandboxOperationKindStop:
			operation, err = c.beginStop(
				ctx,
				sandbox,
				true,
				idempotencyKey,
			)
		case store.SandboxOperationKindDelete:
			operation, err = c.beginDelete(ctx, sandbox, idempotencyKey)
		}
		if IsConflict(err) {
			return c.pendingTerminationOperation(ctx, sandbox)
		}
		return operation, err
	}
	return nil, store.ErrSandboxConflict
}

func (c *Controller) pendingTerminationOperation(
	ctx context.Context,
	sandbox *store.SandboxRecord,
) (*store.SandboxOperation, error) {
	pending, err := c.store.ListPendingSandboxOperationsByHost(
		ctx,
		sandbox.HostID,
	)
	if err != nil {
		return nil, err
	}
	for index := range pending {
		if pending[index].Sandbox.ID == sandbox.ID {
			return &pending[index].Operation, nil
		}
	}
	return nil, store.ErrSandboxConflict
}

func matchingTerminationStage(
	operation *store.SandboxOperation,
	kind string,
) bool {
	if operation == nil || operation.Kind != kind {
		return false
	}
	return kind != store.SandboxOperationKindStop ||
		operation.DeleteAfterStop
}

func protocolTerminationStage(kind string) bool {
	return kind == store.SandboxOperationKindStop ||
		kind == store.SandboxOperationKindDelete
}

func terminationStageKey(root string, kind string) (string, error) {
	rootID, err := uuid.Parse(root)
	if err != nil {
		return "", store.ErrSandboxConflict
	}
	return uuid.NewSHA1(rootID, []byte("termination:"+kind)).String(), nil
}

func terminationRetryKey(operationID string) (string, error) {
	parsed, err := uuid.Parse(operationID)
	if err != nil {
		return "", store.ErrSandboxConflict
	}
	return uuid.NewSHA1(parsed, []byte("termination:retry")).String(), nil
}

func terminationRetryDue(updatedAt time.Time, now time.Time) bool {
	return !now.Before(updatedAt.Add(dispatchRetryInterval))
}
