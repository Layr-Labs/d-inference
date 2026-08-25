package sandboxcontrol

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func (c *Controller) runLeaseSweeper(ctx context.Context) {
	defer close(c.done)
	ticker := time.NewTicker(leaseSweepInterval)
	defer ticker.Stop()
	for {
		if err := c.sweepExpiredCommands(ctx); err != nil &&
			!errors.Is(err, context.Canceled) {
			// The next bounded sweep retries durable rows.
		}
		if err := c.sweepExpiredLeases(ctx); err != nil &&
			!errors.Is(err, context.Canceled) {
			// The next bounded sweep retries durable rows. Individual failures
			// never terminate lease enforcement for the rest of the process.
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (c *Controller) sweepExpiredCommands(ctx context.Context) error {
	sweepContext, cancel := context.WithTimeout(ctx, dispatchTimeout)
	defer cancel()
	now := c.now().UTC()
	commands, err := c.store.ListExpiringSandboxCommands(
		sweepContext,
		now,
		store.MaxSandboxListLimit,
	)
	if err != nil {
		return err
	}
	for index := range commands {
		pending := &commands[index]
		_, err := c.store.ApplySandboxCommandUpdate(
			sweepContext,
			store.SandboxCommandUpdate{
				CommandID:    pending.Command.ID,
				SandboxID:    pending.Sandbox.ID,
				Generation:   pending.Command.Generation,
				FencingToken: pending.Command.FencingToken,
				State:        store.SandboxCommandTimedOut,
				ErrorCode:    "command_deadline_exceeded",
				UpdatedAt:    now,
			},
		)
		if err != nil {
			if IsConflict(err) || errors.Is(err, store.ErrNotFound) {
				continue
			}
			return err
		}
		c.cancelExpiredCommand(&pending.Sandbox, &pending.Command)
		if pending.Sandbox.TerminationRequested {
			if err := c.driveTermination(
				sweepContext,
				&pending.Sandbox,
			); err != nil &&
				!IsConflict(err) &&
				!errors.Is(err, ErrHostUnavailable) {
				return err
			}
		}
	}
	return nil
}

func (c *Controller) cancelExpiredCommand(
	sandbox *store.SandboxRecord,
	command *store.SandboxCommand,
) {
	if sandbox == nil || command == nil {
		return
	}
	session, exists := c.hosts.Session(sandbox.HostID)
	if !exists {
		return
	}
	sendContext, cancel := context.WithTimeout(
		context.Background(),
		dispatchTimeout,
	)
	defer cancel()
	_ = session.Send(
		sendContext,
		protocol.SandboxTypeCancelCommand,
		protocol.SandboxCommandControlPayload{
			OperationID: uuid.NewString(),
			CommandID:   command.ID,
			Scope: protocol.SandboxScope{
				SandboxID:    command.SandboxID,
				Generation:   command.Generation,
				FencingToken: command.FencingToken,
			},
		},
	)
}

func (c *Controller) sweepExpiredLeases(ctx context.Context) error {
	sweepContext, cancel := context.WithTimeout(ctx, dispatchTimeout)
	defer cancel()
	sandboxes, err := c.store.ListExpiringSandboxes(
		sweepContext,
		c.now().UTC(),
		store.MaxSandboxListLimit,
	)
	if err != nil {
		return err
	}
	for index := range sandboxes {
		sandbox := &sandboxes[index]
		idempotencyKey := sandbox.TerminationIdempotencyKey
		if idempotencyKey == "" {
			idempotencyKey = uuid.NewString()
		}
		updated, err := c.store.MarkSandboxTerminationRequested(
			sweepContext,
			sandbox.AccountID,
			sandbox.ID,
			idempotencyKey,
			c.now().UTC(),
		)
		if err != nil {
			if errors.Is(err, store.ErrNotFound) {
				continue
			}
			return err
		}
		if err := c.driveTermination(sweepContext, updated); err != nil &&
			!IsConflict(err) &&
			!errors.Is(err, ErrHostUnavailable) {
			return err
		}
	}
	return nil
}
