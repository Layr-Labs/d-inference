package sandboxcontrol

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func (c *Controller) dispatchOperation(
	sandbox *store.SandboxRecord,
	operation *store.SandboxOperation,
) error {
	if sandbox == nil ||
		operation == nil ||
		operation.Terminal() ||
		operation.State == store.SandboxOperationQueued {
		return store.ErrSandboxConflict
	}
	session, exists := c.hosts.Session(sandbox.HostID)
	if !exists {
		return c.recordOperationDispatch(operation.ID, ErrHostUnavailable)
	}
	scope := protocol.SandboxScope{
		SandboxID:    operation.SandboxID,
		Generation:   operation.Generation,
		FencingToken: operation.FencingToken,
	}
	switch operation.Kind {
	case store.SandboxOperationKindPrepare:
		return c.sendOperation(
			session,
			operation,
			protocol.SandboxTypePrepare,
			protocol.SandboxPreparePayload{
				OperationID: operation.ID,
				Scope:       scope,
				Resources: protocol.SandboxResources{
					CPUCount:              sandbox.CPUCount,
					MemoryBytes:           sandbox.MemoryBytes,
					WorkspaceBytes:        sandbox.WorkspaceBytes,
					CommandTimeoutSeconds: sandbox.CommandTimeoutSeconds,
					GPU:                   sandbox.GPU,
				},
				BaseImageID: sandbox.BaseImageID,
				LeaseExpiresAt: sandbox.LeaseExpiresAt.Format(
					time.RFC3339Nano,
				),
			},
		)
	case store.SandboxOperationKindRenew:
		if operation.RequestedFencingToken == 0 {
			return store.ErrSandboxInvalidTransition
		}
		return c.sendOperation(
			session,
			operation,
			protocol.SandboxTypeLeaseRenew,
			protocol.SandboxLeaseRenewPayload{
				OperationID:           operation.ID,
				Scope:                 scope,
				RequestedFencingToken: operation.RequestedFencingToken,
				LeaseExpiresAt: operation.RequestedLeaseExpiresAt.Format(
					time.RFC3339Nano,
				),
			},
		)
	case store.SandboxOperationKindStop:
		ctx, cancel := context.WithTimeout(context.Background(), dispatchTimeout)
		active, err := c.store.ListActiveSandboxCommands(
			ctx,
			sandbox.ID,
		)
		cancel()
		if err != nil {
			return err
		}
		if len(active) > 0 {
			return store.ErrSandboxConflict
		}
		return c.sendOperation(
			session,
			operation,
			protocol.SandboxTypeStop,
			protocol.SandboxOperationPayload{
				OperationID: operation.ID,
				Scope:       scope,
			},
		)
	case store.SandboxOperationKindDelete:
		return c.sendOperation(
			session,
			operation,
			protocol.SandboxTypeDelete,
			protocol.SandboxOperationPayload{
				OperationID: operation.ID,
				Scope:       scope,
			},
		)
	default:
		return store.ErrSandboxInvalidTransition
	}
}

func (c *Controller) dispatchCommand(
	sandbox *store.SandboxRecord,
	command *store.SandboxCommand,
) error {
	if sandbox == nil || command == nil || command.Terminal() {
		return store.ErrSandboxConflict
	}
	timeoutSeconds, ok := commandDispatchTimeoutSeconds(
		command,
		c.now().UTC(),
	)
	if !ok {
		return store.ErrSandboxInvalidTransition
	}
	session, exists := c.hosts.Session(sandbox.HostID)
	if !exists {
		return c.recordCommandDispatch(command.ID, ErrHostUnavailable)
	}
	var workingDirectory *string
	if command.WorkingDirectory != "" {
		value := command.WorkingDirectory
		workingDirectory = &value
	}
	return c.sendCommand(
		session,
		command,
		protocol.SandboxCommandPayload{
			CommandID:      command.ID,
			IdempotencyKey: command.IdempotencyKey,
			Scope: protocol.SandboxScope{
				SandboxID:    command.SandboxID,
				Generation:   command.Generation,
				FencingToken: command.FencingToken,
			},
			Arguments:        append([]string(nil), command.Arguments...),
			Environment:      cloneEnvironment(command.Environment),
			WorkingDirectory: workingDirectory,
			TimeoutSeconds:   timeoutSeconds,
		},
	)
}

func commandDispatchTimeoutSeconds(
	command *store.SandboxCommand,
	now time.Time,
) (uint32, bool) {
	if command == nil || command.TimeoutSeconds == 0 ||
		command.DeadlineReached(now) {
		return 0, false
	}
	seconds := uint64(command.Deadline().Sub(now) / time.Second)
	if seconds == 0 {
		if command.LastDispatchedAt != nil {
			return 0, false
		}
		return 1, true
	}
	if seconds > uint64(command.TimeoutSeconds) {
		seconds = uint64(command.TimeoutSeconds)
	}
	return uint32(seconds), true
}

func (c *Controller) sendOperation(
	session *sandboxhost.Session,
	operation *store.SandboxOperation,
	messageType string,
	payload any,
) error {
	sendContext, cancelSend := context.WithTimeout(
		context.Background(),
		dispatchTimeout,
	)
	err := session.Send(sendContext, messageType, payload)
	cancelSend()
	recordContext, cancelRecord := context.WithTimeout(
		context.Background(),
		dispatchTimeout,
	)
	defer cancelRecord()
	recordErr := c.store.RecordSandboxOperationDispatch(
		recordContext,
		operation.ID,
		c.now().UTC(),
		dispatchError(err),
	)
	if err != nil {
		return err
	}
	return recordErr
}

func (c *Controller) sendCommand(
	session *sandboxhost.Session,
	command *store.SandboxCommand,
	payload protocol.SandboxCommandPayload,
) error {
	sendContext, cancelSend := context.WithTimeout(
		context.Background(),
		dispatchTimeout,
	)
	err := session.Send(sendContext, protocol.SandboxTypeCommand, payload)
	cancelSend()
	recordContext, cancelRecord := context.WithTimeout(
		context.Background(),
		dispatchTimeout,
	)
	defer cancelRecord()
	recordErr := c.store.RecordSandboxCommandDispatch(
		recordContext,
		command.ID,
		c.now().UTC(),
		dispatchError(err),
	)
	if err != nil {
		return err
	}
	return recordErr
}

func (c *Controller) recordOperationDispatch(
	operationID string,
	err error,
) error {
	ctx, cancel := context.WithTimeout(context.Background(), dispatchTimeout)
	defer cancel()
	recordErr := c.store.RecordSandboxOperationDispatch(
		ctx,
		operationID,
		c.now().UTC(),
		dispatchError(err),
	)
	if recordErr != nil {
		return recordErr
	}
	return err
}

func (c *Controller) recordCommandDispatch(commandID string, err error) error {
	ctx, cancel := context.WithTimeout(context.Background(), dispatchTimeout)
	defer cancel()
	recordErr := c.store.RecordSandboxCommandDispatch(
		ctx,
		commandID,
		c.now().UTC(),
		dispatchError(err),
	)
	if recordErr != nil {
		return recordErr
	}
	return err
}

func (c *Controller) dispatchCommandCancellation(
	ctx context.Context,
	sandbox *store.SandboxRecord,
	command *store.SandboxCommand,
) error {
	if sandbox == nil || command == nil || !command.CancellationPending {
		return store.ErrSandboxConflict
	}
	session, exists := c.hosts.Session(sandbox.HostID)
	if !exists {
		return c.recordCommandCancellationDispatch(
			ctx,
			command.ID,
			ErrHostUnavailable,
		)
	}
	err := session.Send(
		ctx,
		protocol.SandboxTypeCancelCommand,
		protocol.SandboxCommandControlPayload{
			OperationID: cancellationOperationID(command.ID),
			CommandID:   command.ID,
			Scope: protocol.SandboxScope{
				SandboxID:    command.SandboxID,
				Generation:   command.Generation,
				FencingToken: command.FencingToken,
			},
		},
	)
	recordErr := c.recordCommandCancellationDispatch(ctx, command.ID, err)
	if err != nil {
		return err
	}
	return recordErr
}

func (c *Controller) dispatchSandboxCommandCancellations(
	ctx context.Context,
	sandbox *store.SandboxRecord,
) error {
	if sandbox == nil {
		return store.ErrSandboxConflict
	}
	pending, err := c.store.ListPendingSandboxCommandCancellationsByHost(
		ctx,
		sandbox.HostID,
	)
	if err != nil {
		return err
	}
	for index := range pending {
		if pending[index].Sandbox.ID != sandbox.ID {
			continue
		}
		if err := c.dispatchCommandCancellation(
			ctx,
			&pending[index].Sandbox,
			&pending[index].Command,
		); err != nil {
			return err
		}
	}
	return nil
}

func (c *Controller) recordCommandCancellationDispatch(
	ctx context.Context,
	commandID string,
	err error,
) error {
	recordErr := c.store.RecordSandboxCommandCancellationDispatch(
		ctx,
		commandID,
		c.now().UTC(),
		dispatchError(err),
	)
	if recordErr != nil {
		return recordErr
	}
	return err
}

func cancellationOperationID(commandID string) string {
	return uuid.NewSHA1(
		uuid.NameSpaceOID,
		[]byte("sandbox-command-cancel:"+commandID),
	).String()
}

func dispatchError(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, ErrHostUnavailable) ||
		errors.Is(err, sandboxhost.ErrSessionClosed) {
		return "host_unavailable"
	}
	return "dispatch_failed"
}
