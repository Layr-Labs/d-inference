package sandboxcontrol

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

const (
	CommandTimeoutSeconds  uint32 = 900
	LeaseDuration                 = 10 * time.Minute
	HostHeartbeatFreshness        = 60 * time.Second
)

var (
	ErrInvalidRequest      = errors.New("invalid sandbox request")
	ErrNoCapacity          = errors.New("no sandbox host has capacity")
	ErrHostUnavailable     = errors.New("sandbox host unavailable")
	ErrSandboxNotReady     = errors.New("sandbox is not ready")
	ErrIdempotencyConflict = errors.New("sandbox idempotency key payload conflict")
)

type CreateRequest struct {
	BaseImageID    string
	CPUCount       uint16
	MemoryBytes    uint64
	WorkspaceBytes uint64
	GPU            bool
}

type CommandRequest struct {
	IdempotencyKey   string
	Arguments        []string
	Environment      map[string]string
	WorkingDirectory string
	TimeoutSeconds   uint32
}

type Controller struct {
	store store.SandboxStore
	hosts *sandboxhost.Registry
	now   func() time.Time

	scheduleMu    sync.Mutex
	hostNextFence map[string]uint64
}

func New(
	sandboxStore store.SandboxStore,
	hosts *sandboxhost.Registry,
) *Controller {
	controller := &Controller{
		store:         sandboxStore,
		hosts:         hosts,
		now:           time.Now,
		hostNextFence: make(map[string]uint64),
	}
	hosts.SetHandler(controller.HandleHostMessage)
	return controller
}

func (c *Controller) Create(
	ctx context.Context,
	accountID string,
	keyID string,
	request CreateRequest,
) (*store.SandboxRecord, *store.SandboxOperation, error) {
	resources := protocol.SandboxResources{
		CPUCount:              request.CPUCount,
		MemoryBytes:           request.MemoryBytes,
		WorkspaceBytes:        request.WorkspaceBytes,
		CommandTimeoutSeconds: CommandTimeoutSeconds,
		GPU:                   request.GPU,
	}
	if accountID == "" ||
		!protocol.ValidSandboxIdentifier(request.BaseImageID) ||
		protocol.ValidateSandboxResources(resources) != nil ||
		request.GPU {
		return nil, nil, ErrInvalidRequest
	}
	now := c.now().UTC()
	leaseExpiresAt := now.Add(LeaseDuration)

	c.scheduleMu.Lock()
	session, fencingToken, err := c.selectHostLocked(ctx, resources, now)
	if err != nil {
		c.scheduleMu.Unlock()
		return nil, nil, err
	}
	sandboxID := uuid.NewString()
	operationID := uuid.NewString()
	sandbox := &store.SandboxRecord{
		ID:                    sandboxID,
		AccountID:             accountID,
		CreatedByKeyID:        keyID,
		HostID:                session.HostID(),
		Generation:            1,
		FencingToken:          fencingToken,
		BaseImageID:           request.BaseImageID,
		CPUCount:              request.CPUCount,
		MemoryBytes:           request.MemoryBytes,
		WorkspaceBytes:        request.WorkspaceBytes,
		CommandTimeoutSeconds: CommandTimeoutSeconds,
		GPU:                   false,
		State:                 store.SandboxStatePreparing,
		LeaseExpiresAt:        leaseExpiresAt,
		CreatedAt:             now,
		UpdatedAt:             now,
	}
	operation := &store.SandboxOperation{
		ID:                      operationID,
		SandboxID:               sandboxID,
		AccountID:               accountID,
		Kind:                    store.SandboxOperationKindPrepare,
		State:                   store.SandboxOperationPending,
		Generation:              sandbox.Generation,
		FencingToken:            sandbox.FencingToken,
		RequestedLeaseExpiresAt: leaseExpiresAt,
		CreatedAt:               now,
		UpdatedAt:               now,
	}
	if err := c.store.CreateSandbox(ctx, sandbox, operation); err != nil {
		c.scheduleMu.Unlock()
		return nil, nil, err
	}
	c.hostNextFence[sandbox.HostID] = fencingToken + 1
	c.scheduleMu.Unlock()

	payload := protocol.SandboxPreparePayload{
		OperationID:    operation.ID,
		Scope:          sandboxScope(sandbox),
		Resources:      resources,
		BaseImageID:    sandbox.BaseImageID,
		LeaseExpiresAt: sandbox.LeaseExpiresAt.Format(time.RFC3339Nano),
	}
	if err := session.Send(ctx, protocol.SandboxTypePrepare, payload); err != nil {
		c.failOperationDispatch(ctx, sandbox, operation, "host_unavailable")
		return nil, nil, ErrHostUnavailable
	}
	return sandbox, operation, nil
}

func (c *Controller) Get(
	ctx context.Context,
	accountID string,
	sandboxID string,
) (*store.SandboxRecord, error) {
	return c.store.GetSandbox(ctx, accountID, sandboxID)
}

func (c *Controller) List(
	ctx context.Context,
	accountID string,
	limit int,
) ([]store.SandboxRecord, error) {
	return c.store.ListSandboxes(ctx, accountID, limit)
}

func (c *Controller) GetOperation(
	ctx context.Context,
	accountID string,
	operationID string,
) (*store.SandboxOperation, error) {
	return c.store.GetSandboxOperation(ctx, accountID, operationID)
}

func (c *Controller) GetCommand(
	ctx context.Context,
	accountID string,
	sandboxID string,
	commandID string,
) (*store.SandboxCommand, error) {
	return c.store.GetSandboxCommand(ctx, accountID, sandboxID, commandID)
}

func (c *Controller) selectHostLocked(
	ctx context.Context,
	resources protocol.SandboxResources,
	now time.Time,
) (*sandboxhost.Session, uint64, error) {
	snapshots := c.hosts.Snapshots()
	sort.Slice(snapshots, func(left, right int) bool {
		return snapshots[left].HostID < snapshots[right].HostID
	})
	var (
		selected       *sandboxhost.Session
		selectedFence  uint64
		selectedCPU    uint16
		selectedMemory uint64
	)
	for _, snapshot := range snapshots {
		if snapshot.Heartbeat == nil ||
			snapshot.Heartbeat.Mode != "sandbox_dedicated" ||
			snapshot.LastHeartbeat.IsZero() ||
			now.Sub(snapshot.LastHeartbeat) > HostHeartbeatFreshness ||
			!supportsWorkspace(
				snapshot.Capabilities.WorkspaceSizesBytes,
				resources.WorkspaceBytes,
			) ||
			(resources.GPU && !snapshot.Capabilities.SupportsGPU) {
			continue
		}
		session, exists := c.hosts.Session(snapshot.HostID)
		if !exists ||
			session.Snapshot().ConnectionEpoch != snapshot.ConnectionEpoch {
			continue
		}
		active, err := c.store.ListActiveSandboxesByHost(
			ctx,
			snapshot.HostID,
		)
		if err != nil {
			return nil, 0, err
		}
		observed := make(map[string]struct{}, len(snapshot.Heartbeat.Leases))
		for _, lease := range snapshot.Heartbeat.Leases {
			observed[lease.Scope.SandboxID] = struct{}{}
		}
		availableCPU := snapshot.Heartbeat.AvailableCPU
		availableMemory := snapshot.Heartbeat.AvailableMemory
		usedSlots := len(snapshot.Heartbeat.Leases)
		nextFence := snapshot.Heartbeat.NextFencingToken
		for _, sandbox := range active {
			if sandbox.FencingToken >= nextFence &&
				sandbox.FencingToken < ^uint64(0) {
				nextFence = sandbox.FencingToken + 1
			}
			if _, alreadyObserved := observed[sandbox.ID]; alreadyObserved {
				continue
			}
			usedSlots++
			if sandbox.CPUCount > availableCPU {
				availableCPU = 0
			} else {
				availableCPU -= sandbox.CPUCount
			}
			if sandbox.MemoryBytes > availableMemory {
				availableMemory = 0
			} else {
				availableMemory -= sandbox.MemoryBytes
			}
		}
		if local := c.hostNextFence[snapshot.HostID]; local > nextFence {
			nextFence = local
		}
		if usedSlots >= int(snapshot.Capabilities.MaximumSandboxes) ||
			availableCPU < resources.CPUCount ||
			availableMemory < resources.MemoryBytes ||
			nextFence == 0 ||
			nextFence > (^uint64(0)>>1) {
			continue
		}
		if selected == nil ||
			availableCPU > selectedCPU ||
			(availableCPU == selectedCPU &&
				availableMemory > selectedMemory) {
			selected = session
			selectedFence = nextFence
			selectedCPU = availableCPU
			selectedMemory = availableMemory
		}
	}
	if selected == nil {
		return nil, 0, ErrNoCapacity
	}
	return selected, selectedFence, nil
}

func supportsWorkspace(sizes []uint64, requested uint64) bool {
	for _, size := range sizes {
		if size == requested {
			return true
		}
	}
	return false
}

func sandboxScope(sandbox *store.SandboxRecord) protocol.SandboxScope {
	return protocol.SandboxScope{
		SandboxID:    sandbox.ID,
		Generation:   sandbox.Generation,
		FencingToken: sandbox.FencingToken,
	}
}

func (c *Controller) failOperationDispatch(
	ctx context.Context,
	sandbox *store.SandboxRecord,
	operation *store.SandboxOperation,
	errorCode string,
) {
	now := c.now().UTC()
	_, _, _ = c.store.ApplySandboxOperationUpdate(
		ctx,
		store.SandboxOperationUpdate{
			OperationID:  operation.ID,
			SandboxID:    sandbox.ID,
			Generation:   sandbox.Generation,
			FencingToken: sandbox.FencingToken,
			State:        store.SandboxOperationFailed,
			ErrorCode:    errorCode,
			UpdatedAt:    now,
		},
	)
}
