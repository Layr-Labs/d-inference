package sandboxcontrol

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (c *Controller) reconcileHost(
	ctx context.Context,
	session *sandboxhost.Session,
	heartbeat *protocol.SandboxHostHeartbeatPayload,
) error {
	snapshot := session.Snapshot()
	c.scheduleMu.Lock()
	newConnection :=
		c.reconciledEpoch[session.HostID()] != snapshot.ConnectionEpoch
	c.scheduleMu.Unlock()

	pendingOperations, err := c.store.ListPendingSandboxOperationsByHost(
		ctx,
		session.HostID(),
	)
	if err != nil {
		return err
	}
	observed := make(map[string]protocol.SandboxHostLeaseObservation)
	for _, lease := range heartbeat.Leases {
		observed[lease.Scope.SandboxID] = lease
	}
	for index := range pendingOperations {
		pending := &pendingOperations[index]
		confirmed, err := c.applyHeartbeatOperationObservation(
			ctx,
			pending,
			observed[pending.Sandbox.ID],
		)
		if err != nil && !IsConflict(err) {
			return err
		}
		if !confirmed &&
			(newConnection ||
				dispatchDue(
					pending.Operation.LastDispatchedAt,
					c.now().UTC(),
				)) {
			_ = c.dispatchOperation(&pending.Sandbox, &pending.Operation)
		}
	}

	pendingCommands, err := c.store.ListPendingSandboxCommandsByHost(
		ctx,
		session.HostID(),
	)
	if err != nil {
		return err
	}
	for index := range pendingCommands {
		pending := &pendingCommands[index]
		if pending.Sandbox.State != store.SandboxStateReady ||
			pending.Sandbox.TerminationRequested ||
			(!newConnection &&
				!dispatchDue(
					pending.Command.LastDispatchedAt,
					c.now().UTC(),
				)) {
			continue
		}
		_ = c.dispatchCommand(&pending.Sandbox, &pending.Command)
	}
	c.scheduleMu.Lock()
	if current, exists := c.hosts.Session(session.HostID()); exists &&
		current == session {
		c.reconciledEpoch[session.HostID()] = snapshot.ConnectionEpoch
	}
	c.scheduleMu.Unlock()
	return nil
}

func dispatchDue(lastAttempt *time.Time, now time.Time) bool {
	return lastAttempt == nil ||
		!now.Before(lastAttempt.Add(dispatchRetryInterval))
}

func (c *Controller) applyHeartbeatOperationObservation(
	ctx context.Context,
	pending *store.PendingSandboxOperation,
	observation protocol.SandboxHostLeaseObservation,
) (bool, error) {
	if pending == nil ||
		observation.Scope.SandboxID != pending.Sandbox.ID ||
		observation.Scope.Generation != pending.Operation.Generation {
		return false, nil
	}
	operation := &pending.Operation
	switch operation.Kind {
	case store.SandboxOperationKindPrepare:
		if observation.Scope.FencingToken != operation.FencingToken {
			return false, nil
		}
		switch observation.State {
		case protocol.SandboxOperationPreparing,
			protocol.SandboxOperationBooting,
			protocol.SandboxOperationReady,
			protocol.SandboxOperationFailed:
			_, _, err := c.store.ApplySandboxOperationUpdate(
				ctx,
				store.SandboxOperationUpdate{
					OperationID:  operation.ID,
					SandboxID:    operation.SandboxID,
					Generation:   operation.Generation,
					FencingToken: operation.FencingToken,
					State:        observation.State,
					UpdatedAt:    c.now().UTC(),
				},
			)
			return true, err
		}
	case store.SandboxOperationKindRenew:
		if observation.Scope.FencingToken <= operation.FencingToken {
			return false, nil
		}
		expiresAt, err := time.Parse(time.RFC3339Nano, observation.LeaseExpiresAt)
		if err != nil ||
			expiresAt.Before(operation.RequestedLeaseExpiresAt) {
			return false, nil
		}
		state := store.SandboxOperationReady
		if operation.PreviousSandboxState == store.SandboxStateStopped {
			state = store.SandboxOperationStopped
		}
		_, _, err = c.store.ApplySandboxOperationUpdate(
			ctx,
			store.SandboxOperationUpdate{
				OperationID:    operation.ID,
				SandboxID:      operation.SandboxID,
				Generation:     operation.Generation,
				FencingToken:   observation.Scope.FencingToken,
				State:          state,
				LeaseExpiresAt: &expiresAt,
				UpdatedAt:      c.now().UTC(),
			},
		)
		return true, err
	case store.SandboxOperationKindStop:
		if observation.Scope.FencingToken != operation.FencingToken {
			return false, nil
		}
		switch observation.State {
		case protocol.SandboxOperationStopping,
			protocol.SandboxOperationStopped:
			_, _, err := c.store.ApplySandboxOperationUpdate(
				ctx,
				store.SandboxOperationUpdate{
					OperationID:  operation.ID,
					SandboxID:    operation.SandboxID,
					Generation:   operation.Generation,
					FencingToken: operation.FencingToken,
					State:        observation.State,
					UpdatedAt:    c.now().UTC(),
				},
			)
			return true, err
		}
	case store.SandboxOperationKindDelete:
		if observation.Scope.FencingToken == operation.FencingToken &&
			observation.State == protocol.SandboxOperationDeleting {
			_, _, err := c.store.ApplySandboxOperationUpdate(
				ctx,
				store.SandboxOperationUpdate{
					OperationID:  operation.ID,
					SandboxID:    operation.SandboxID,
					Generation:   operation.Generation,
					FencingToken: operation.FencingToken,
					State:        observation.State,
					UpdatedAt:    c.now().UTC(),
				},
			)
			return true, err
		}
	}
	return false, nil
}
