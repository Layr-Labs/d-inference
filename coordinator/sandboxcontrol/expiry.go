package sandboxcontrol

import (
	"context"
	"errors"
	"time"

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
		if err := c.sweepPendingCommandCancellations(ctx); err != nil &&
			!errors.Is(err, context.Canceled) {
			// The next bounded sweep or host reconnect retries durable rows.
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
		_, err := c.expireSandboxCommand(sweepContext, pending, now)
		if err != nil {
			return err
		}
	}
	return nil
}

func (c *Controller) expireSandboxCommand(
	ctx context.Context,
	pending *store.PendingSandboxCommand,
	now time.Time,
) (bool, error) {
	if pending == nil || !pending.Command.DeadlineReached(now) {
		return false, nil
	}
	command, err := c.store.ApplySandboxCommandUpdate(
		ctx,
		store.SandboxCommandUpdate{
			CommandID:           pending.Command.ID,
			SandboxID:           pending.Sandbox.ID,
			Generation:          pending.Command.Generation,
			FencingToken:        pending.Command.FencingToken,
			State:               store.SandboxCommandTimedOut,
			ErrorCode:           store.SandboxCommandDeadlineExceeded,
			RequestCancellation: true,
			UpdatedAt:           now,
		},
	)
	if err != nil {
		if IsConflict(err) || errors.Is(err, store.ErrNotFound) {
			return true, nil
		}
		return true, err
	}
	_ = c.dispatchCommandCancellation(ctx, &pending.Sandbox, command)
	if pending.Sandbox.TerminationRequested {
		if err := c.driveTermination(ctx, &pending.Sandbox); err != nil &&
			!IsConflict(err) &&
			!errors.Is(err, ErrHostUnavailable) {
			return true, err
		}
	}
	return true, nil
}

func (c *Controller) sweepPendingCommandCancellations(
	ctx context.Context,
) error {
	sweepContext, cancel := context.WithTimeout(ctx, dispatchTimeout)
	defer cancel()
	now := c.now().UTC()
	hosts := c.hosts.Snapshots()
	hostIDs := make([]string, 0, len(hosts))
	for _, host := range hosts {
		hostIDs = append(hostIDs, host.HostID)
	}
	pending, err := c.store.ListPendingSandboxCommandCancellations(
		sweepContext,
		hostIDs,
		cancellationSweepBatchLimit,
	)
	if err != nil {
		return err
	}
	for index := range pending {
		command := &pending[index].Command
		if !dispatchDue(command.LastCancelDispatchedAt, now) {
			continue
		}
		if err := c.dispatchCommandCancellation(
			sweepContext,
			&pending[index].Sandbox,
			command,
		); err != nil &&
			!errors.Is(err, ErrHostUnavailable) {
			return err
		}
	}
	return nil
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
