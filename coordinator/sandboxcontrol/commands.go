package sandboxcontrol

import (
	"context"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (c *Controller) ListCommands(ctx context.Context, accountID, sandboxID string, limit int) ([]store.SandboxCommandSummary, error) {
	return c.store.ListSandboxCommands(ctx, accountID, sandboxID, limit)
}

// CancelCommand commits cancellation intent before contacting the host. A
// cancelled result with cancellation_pending=true is still active work until
// the host acknowledges cleanup, so callers cannot race a replacement command.
func (c *Controller) CancelCommand(ctx context.Context, accountID, sandboxID, commandID string) (*store.SandboxCommand, error) {
	command, err := c.store.GetSandboxCommand(ctx, accountID, sandboxID, commandID)
	if err != nil {
		return nil, err
	}
	sandbox, err := c.store.GetSandbox(ctx, accountID, sandboxID)
	if err != nil {
		return nil, err
	}
	if !command.Terminal() {
		command, err = c.store.ApplySandboxCommandUpdate(ctx, store.SandboxCommandUpdate{
			CommandID:           command.ID,
			SandboxID:           command.SandboxID,
			Generation:          command.Generation,
			FencingToken:        command.FencingToken,
			State:               store.SandboxCommandCancelled,
			ErrorCode:           "cancelled_by_user",
			RequestCancellation: true,
			UpdatedAt:           c.now().UTC(),
		})
		if err != nil {
			if !IsConflict(err) && !errors.Is(err, store.ErrSandboxInvalidTransition) {
				return nil, err
			}
			// Completion or a concurrent cancellation can win the store lock.
			// Return its durable result instead of rewriting a finished command.
			current, readErr := c.store.GetSandboxCommand(ctx, accountID, sandboxID, commandID)
			if readErr != nil {
				return nil, readErr
			}
			if !current.Terminal() {
				return nil, err
			}
			command = current
		}
	}
	if command.CancellationPending {
		// Failure to deliver does not undo an accepted cancellation. The durable
		// outbox retries on its bounded sweep and on host reconnect.
		_ = c.dispatchCommandCancellation(ctx, sandbox, command)
	}
	return c.store.GetSandboxCommand(ctx, accountID, sandboxID, commandID)
}
