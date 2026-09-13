package sandboxcontrol

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (c *Controller) observeStoppedLeases(ctx context.Context, session *sandboxhost.Session, heartbeat *protocol.SandboxHostHeartbeatPayload) error {
	current, exists := c.hosts.Session(session.HostID())
	if !exists || current != session {
		return sandboxhost.ErrSessionClosed
	}
	// Session.Handle already binds ctx to this connection's authority. Add a
	// bound for row locks without detaching cancellation on disconnect.
	observationContext, cancel := context.WithTimeout(ctx, dispatchTimeout)
	defer cancel()
	for _, lease := range heartbeat.Leases {
		if lease.State != protocol.SandboxOperationStopped {
			continue
		}
		expiry, err := time.Parse(time.RFC3339Nano, lease.LeaseExpiresAt)
		if err != nil {
			continue
		}
		if _, err := c.store.ObserveSandboxStopped(observationContext, store.SandboxStoppedObservation{
			SandboxID: lease.Scope.SandboxID, HostID: session.HostID(), Generation: lease.Scope.Generation, FencingToken: lease.Scope.FencingToken,
			CPUCount: lease.Resources.CPUCount, MemoryBytes: lease.Resources.MemoryBytes, WorkspaceBytes: lease.Resources.WorkspaceBytes,
			CommandTimeoutSeconds: lease.Resources.CommandTimeoutSeconds, GPU: lease.Resources.GPU, LeaseExpiresAt: expiry, ObservedAt: c.now().UTC(),
		}); err != nil {
			return err
		}
	}
	return nil
}
