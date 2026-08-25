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
	CommandTimeoutSeconds      uint32 = 900
	LeaseDuration                     = 30 * time.Minute
	HostHeartbeatFreshness            = 60 * time.Second
	MaximumActiveSandboxes            = 4
	MaximumSandboxesPerAccount        = 2
	dispatchTimeout                   = 5 * time.Second
	dispatchRetryInterval             = 15 * time.Second
	leaseSweepInterval                = 5 * time.Second
)

var (
	ErrInvalidRequest      = errors.New("invalid sandbox request")
	ErrNoCapacity          = errors.New("no sandbox host has capacity")
	ErrHostUnavailable     = errors.New("sandbox host unavailable")
	ErrSandboxNotReady     = errors.New("sandbox is not ready")
	ErrIdempotencyConflict = errors.New("sandbox idempotency key payload conflict")
)

type CreateRequest struct {
	IdempotencyKey string
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

	scheduleMu      sync.Mutex
	hostNextFence   map[string]uint64
	reconciledEpoch map[string]string

	cancel context.CancelFunc
	done   chan struct{}
}

func New(
	sandboxStore store.SandboxStore,
	hosts *sandboxhost.Registry,
) *Controller {
	runContext, cancel := context.WithCancel(context.Background())
	controller := &Controller{
		store:           sandboxStore,
		hosts:           hosts,
		now:             time.Now,
		hostNextFence:   make(map[string]uint64),
		reconciledEpoch: make(map[string]string),
		cancel:          cancel,
		done:            make(chan struct{}),
	}
	hosts.SetHandler(controller.HandleHostMessage)
	go controller.runLeaseSweeper(runContext)
	return controller
}

func (c *Controller) Close() {
	c.cancel()
	<-c.done
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
		!protocol.ValidSandboxUUID(request.IdempotencyKey) ||
		!protocol.ValidSandboxIdentifier(request.BaseImageID) ||
		protocol.ValidateSandboxResources(resources) != nil ||
		request.GPU {
		return nil, nil, ErrInvalidRequest
	}
	existing, existingOperation, err := c.store.GetSandboxByIdempotency(
		ctx,
		accountID,
		request.IdempotencyKey,
	)
	if err == nil {
		candidate := &store.SandboxRecord{
			AccountID:             accountID,
			IdempotencyKey:        request.IdempotencyKey,
			BaseImageID:           request.BaseImageID,
			CPUCount:              request.CPUCount,
			MemoryBytes:           request.MemoryBytes,
			WorkspaceBytes:        request.WorkspaceBytes,
			CommandTimeoutSeconds: CommandTimeoutSeconds,
			GPU:                   request.GPU,
		}
		if !existing.SameAllocationRequest(candidate) {
			return nil, nil, ErrIdempotencyConflict
		}
		return existing, existingOperation, nil
	}
	if !errors.Is(err, store.ErrNotFound) {
		return nil, nil, err
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
		IdempotencyKey:        request.IdempotencyKey,
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
		IdempotencyKey:          request.IdempotencyKey,
		Kind:                    store.SandboxOperationKindPrepare,
		State:                   store.SandboxOperationPending,
		Generation:              sandbox.Generation,
		FencingToken:            sandbox.FencingToken,
		RequestedLeaseExpiresAt: leaseExpiresAt,
		CreatedAt:               now,
		UpdatedAt:               now,
	}
	storedSandbox, storedOperation, created, err := c.store.CreateSandbox(
		ctx,
		sandbox,
		operation,
		store.SandboxAllocationLimits{
			MaximumActive:     MaximumActiveSandboxes,
			MaximumPerAccount: MaximumSandboxesPerAccount,
			MaximumPerHost:    int(session.Snapshot().Capabilities.MaximumSandboxes),
		},
	)
	if err != nil {
		c.scheduleMu.Unlock()
		return nil, nil, err
	}
	if !storedSandbox.SameAllocationRequest(sandbox) {
		c.scheduleMu.Unlock()
		return nil, nil, ErrIdempotencyConflict
	}
	if !created {
		c.scheduleMu.Unlock()
		return storedSandbox, storedOperation, nil
	}
	c.hostNextFence[sandbox.HostID] = fencingToken + 1
	c.scheduleMu.Unlock()

	payload := protocol.SandboxPreparePayload{
		OperationID:    storedOperation.ID,
		Scope:          sandboxScope(storedSandbox),
		Resources:      resources,
		BaseImageID:    storedSandbox.BaseImageID,
		LeaseExpiresAt: storedSandbox.LeaseExpiresAt.Format(time.RFC3339Nano),
	}
	_ = c.sendOperation(session, storedOperation, protocol.SandboxTypePrepare, payload)
	return storedSandbox, storedOperation, nil
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
