package store

import (
	"context"
	"fmt"
	"sort"
)

func (s *MemoryStore) CreateSandbox(
	_ context.Context,
	sandbox *SandboxRecord,
	operation *SandboxOperation,
) error {
	if err := validateSandboxCreate(sandbox, operation); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.sandboxes[sandbox.ID]; exists {
		return ErrSandboxConflict
	}
	if _, exists := s.sandboxOperations[operation.ID]; exists {
		return ErrSandboxConflict
	}
	s.sandboxes[sandbox.ID] = cloneSandboxRecord(sandbox)
	s.sandboxOperations[operation.ID] = cloneSandboxOperation(operation)
	return nil
}

func (s *MemoryStore) GetSandbox(
	_ context.Context,
	accountID string,
	sandboxID string,
) (*SandboxRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sandbox := s.sandboxes[sandboxID]
	if sandbox == nil || sandbox.AccountID != accountID {
		return nil, fmt.Errorf("sandbox %s: %w", sandboxID, ErrNotFound)
	}
	return cloneSandboxRecord(sandbox), nil
}

func (s *MemoryStore) GetSandboxByID(
	_ context.Context,
	sandboxID string,
) (*SandboxRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sandbox := s.sandboxes[sandboxID]
	if sandbox == nil {
		return nil, fmt.Errorf("sandbox %s: %w", sandboxID, ErrNotFound)
	}
	return cloneSandboxRecord(sandbox), nil
}

func (s *MemoryStore) ListSandboxes(
	_ context.Context,
	accountID string,
	limit int,
) ([]SandboxRecord, error) {
	limit = sandboxListLimit(limit)
	s.mu.RLock()
	result := make([]SandboxRecord, 0)
	for _, sandbox := range s.sandboxes {
		if sandbox.AccountID == accountID {
			result = append(result, *cloneSandboxRecord(sandbox))
		}
	}
	s.mu.RUnlock()
	sort.Slice(result, func(left, right int) bool {
		return result[left].CreatedAt.After(result[right].CreatedAt)
	})
	if len(result) > limit {
		result = result[:limit]
	}
	return result, nil
}

func (s *MemoryStore) ListActiveSandboxesByHost(
	_ context.Context,
	hostID string,
) ([]SandboxRecord, error) {
	s.mu.RLock()
	result := make([]SandboxRecord, 0)
	for _, sandbox := range s.sandboxes {
		if sandbox.HostID == hostID && sandbox.ConsumesCapacity() {
			result = append(result, *cloneSandboxRecord(sandbox))
		}
	}
	s.mu.RUnlock()
	sort.Slice(result, func(left, right int) bool {
		return result[left].CreatedAt.Before(result[right].CreatedAt)
	})
	return result, nil
}

func (s *MemoryStore) BeginSandboxOperation(
	_ context.Context,
	operation *SandboxOperation,
	targetState string,
) (*SandboxRecord, error) {
	if err := validateSandboxOperationStart(operation, targetState); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	sandbox := s.sandboxes[operation.SandboxID]
	if sandbox == nil || sandbox.AccountID != operation.AccountID {
		return nil, fmt.Errorf("sandbox %s: %w", operation.SandboxID, ErrNotFound)
	}
	if sandbox.Generation != operation.Generation ||
		sandbox.FencingToken != operation.FencingToken ||
		sandbox.State != operation.PreviousSandboxState ||
		sandbox.Terminal() {
		return nil, ErrSandboxConflict
	}
	if _, exists := s.sandboxOperations[operation.ID]; exists {
		return nil, ErrSandboxConflict
	}
	for _, existing := range s.sandboxOperations {
		if existing.SandboxID == operation.SandboxID && !existing.Terminal() {
			return nil, ErrSandboxConflict
		}
	}
	sandbox.State = targetState
	if operation.Kind == SandboxOperationKindDelete ||
		operation.DeleteAfterStop {
		sandbox.TerminationRequested = true
	}
	sandbox.ErrorCode = ""
	sandbox.UpdatedAt = operation.UpdatedAt
	s.sandboxOperations[operation.ID] = cloneSandboxOperation(operation)
	return cloneSandboxRecord(sandbox), nil
}

func (s *MemoryStore) GetSandboxOperation(
	_ context.Context,
	accountID string,
	operationID string,
) (*SandboxOperation, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	operation := s.sandboxOperations[operationID]
	if operation == nil || operation.AccountID != accountID {
		return nil, fmt.Errorf("sandbox operation %s: %w", operationID, ErrNotFound)
	}
	return cloneSandboxOperation(operation), nil
}

func (s *MemoryStore) ApplySandboxOperationUpdate(
	_ context.Context,
	update SandboxOperationUpdate,
) (*SandboxRecord, *SandboxOperation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sandbox := cloneSandboxRecord(s.sandboxes[update.SandboxID])
	operation := cloneSandboxOperation(s.sandboxOperations[update.OperationID])
	if sandbox == nil || operation == nil {
		return nil, nil, ErrNotFound
	}
	if err := applySandboxOperationTransition(sandbox, operation, update); err != nil {
		return nil, nil, err
	}
	s.sandboxes[sandbox.ID] = sandbox
	s.sandboxOperations[operation.ID] = operation
	return cloneSandboxRecord(sandbox), cloneSandboxOperation(operation), nil
}

func (s *MemoryStore) CreateSandboxCommand(
	_ context.Context,
	command *SandboxCommand,
) (*SandboxCommand, bool, error) {
	if err := validateSandboxCommandCreate(command); err != nil {
		return nil, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	sandbox := s.sandboxes[command.SandboxID]
	if sandbox == nil || sandbox.AccountID != command.AccountID {
		return nil, false, fmt.Errorf(
			"sandbox %s: %w",
			command.SandboxID,
			ErrNotFound,
		)
	}
	if sandbox.State != SandboxStateReady ||
		sandbox.Generation != command.Generation ||
		sandbox.FencingToken != command.FencingToken {
		return nil, false, ErrSandboxConflict
	}
	idempotencyIndex := sandboxCommandIdempotencyIndex(
		command.AccountID,
		command.SandboxID,
		command.IdempotencyKey,
	)
	if existingID := s.sandboxCommandByIdempotency[idempotencyIndex]; existingID != "" {
		return cloneSandboxCommand(s.sandboxCommands[existingID]), false, nil
	}
	if _, exists := s.sandboxCommands[command.ID]; exists {
		return nil, false, ErrSandboxConflict
	}
	s.sandboxCommands[command.ID] = cloneSandboxCommand(command)
	s.sandboxCommandByIdempotency[idempotencyIndex] = command.ID
	return cloneSandboxCommand(command), true, nil
}

func (s *MemoryStore) GetSandboxCommand(
	_ context.Context,
	accountID string,
	sandboxID string,
	commandID string,
) (*SandboxCommand, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	command := s.sandboxCommands[commandID]
	if command == nil ||
		command.AccountID != accountID ||
		command.SandboxID != sandboxID {
		return nil, fmt.Errorf("sandbox command %s: %w", commandID, ErrNotFound)
	}
	return cloneSandboxCommand(command), nil
}

func (s *MemoryStore) ApplySandboxCommandUpdate(
	_ context.Context,
	update SandboxCommandUpdate,
) (*SandboxCommand, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sandbox := s.sandboxes[update.SandboxID]
	command := cloneSandboxCommand(s.sandboxCommands[update.CommandID])
	if sandbox == nil || command == nil {
		return nil, ErrNotFound
	}
	if sandbox.Generation != update.Generation ||
		sandbox.FencingToken != update.FencingToken {
		return nil, ErrSandboxConflict
	}
	if err := applySandboxCommandTransition(command, update); err != nil {
		return nil, err
	}
	s.sandboxCommands[command.ID] = command
	return cloneSandboxCommand(command), nil
}

func sandboxListLimit(limit int) int {
	if limit <= 0 || limit > MaxSandboxListLimit {
		return MaxSandboxListLimit
	}
	return limit
}

func sandboxCommandIdempotencyIndex(
	accountID string,
	sandboxID string,
	idempotencyKey string,
) string {
	return accountID + "\x00" + sandboxID + "\x00" + idempotencyKey
}

func validateSandboxCreate(
	sandbox *SandboxRecord,
	operation *SandboxOperation,
) error {
	if sandbox == nil || operation == nil ||
		sandbox.ID == "" ||
		sandbox.AccountID == "" ||
		sandbox.HostID == "" ||
		sandbox.Generation == 0 ||
		sandbox.FencingToken == 0 ||
		sandbox.State != SandboxStatePreparing ||
		sandbox.CreatedAt.IsZero() ||
		sandbox.UpdatedAt.IsZero() ||
		operation.ID == "" ||
		operation.SandboxID != sandbox.ID ||
		operation.AccountID != sandbox.AccountID ||
		operation.Kind != SandboxOperationKindPrepare ||
		operation.State != SandboxOperationPending ||
		operation.Generation != sandbox.Generation ||
		operation.FencingToken != sandbox.FencingToken ||
		operation.CreatedAt.IsZero() ||
		operation.UpdatedAt.IsZero() {
		return ErrSandboxInvalidTransition
	}
	return nil
}

func validateSandboxOperationStart(
	operation *SandboxOperation,
	targetState string,
) error {
	if operation == nil ||
		operation.ID == "" ||
		operation.SandboxID == "" ||
		operation.AccountID == "" ||
		operation.State != SandboxOperationPending ||
		operation.Generation == 0 ||
		operation.FencingToken == 0 ||
		operation.CreatedAt.IsZero() ||
		operation.UpdatedAt.IsZero() {
		return ErrSandboxInvalidTransition
	}
	switch operation.Kind {
	case SandboxOperationKindRenew:
		if targetState != operation.PreviousSandboxState ||
			operation.RequestedLeaseExpiresAt.IsZero() {
			return ErrSandboxInvalidTransition
		}
	case SandboxOperationKindStop:
		if targetState != SandboxStateStopping ||
			operation.PreviousSandboxState != SandboxStateReady {
			return ErrSandboxInvalidTransition
		}
	case SandboxOperationKindDelete:
		if targetState != SandboxStateDeleting ||
			(operation.PreviousSandboxState != SandboxStateStopped &&
				operation.PreviousSandboxState != SandboxStateFailed) {
			return ErrSandboxInvalidTransition
		}
	default:
		return ErrSandboxInvalidTransition
	}
	return nil
}

func validateSandboxCommandCreate(command *SandboxCommand) error {
	if command == nil ||
		command.ID == "" ||
		command.SandboxID == "" ||
		command.AccountID == "" ||
		command.IdempotencyKey == "" ||
		command.Generation == 0 ||
		command.FencingToken == 0 ||
		len(command.Arguments) == 0 ||
		command.TimeoutSeconds == 0 ||
		command.State != SandboxCommandPending ||
		command.CreatedAt.IsZero() ||
		command.UpdatedAt.IsZero() {
		return ErrSandboxInvalidTransition
	}
	return nil
}
