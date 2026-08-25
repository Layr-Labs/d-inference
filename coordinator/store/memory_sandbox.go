package store

import (
	"context"
	"fmt"
	"sort"
	"time"
)

func (s *MemoryStore) CreateSandbox(
	_ context.Context,
	sandbox *SandboxRecord,
	operation *SandboxOperation,
	limits SandboxAllocationLimits,
) (*SandboxRecord, *SandboxOperation, bool, error) {
	if err := validateSandboxCreate(sandbox, operation); err != nil {
		return nil, nil, false, err
	}
	if limits.MaximumActive <= 0 ||
		limits.MaximumPerAccount <= 0 ||
		limits.MaximumPerHost <= 0 {
		return nil, nil, false, ErrSandboxInvalidTransition
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	idempotencyIndex := sandboxIdempotencyIndex(
		sandbox.AccountID,
		sandbox.IdempotencyKey,
	)
	if existingID := s.sandboxByIdempotency[idempotencyIndex]; existingID != "" {
		return s.existingSandboxCreateLocked(existingID)
	}
	if _, exists := s.sandboxes[sandbox.ID]; exists {
		return nil, nil, false, ErrSandboxConflict
	}
	if _, exists := s.sandboxOperations[operation.ID]; exists {
		return nil, nil, false, ErrSandboxConflict
	}
	active := 0
	accountActive := 0
	hostActive := 0
	for _, existing := range s.sandboxes {
		if !existing.ConsumesCapacity() {
			continue
		}
		active++
		if existing.AccountID == sandbox.AccountID {
			accountActive++
		}
		if existing.HostID == sandbox.HostID {
			hostActive++
		}
	}
	if active >= limits.MaximumActive ||
		accountActive >= limits.MaximumPerAccount ||
		hostActive >= limits.MaximumPerHost {
		return nil, nil, false, ErrSandboxCapacity
	}
	fencingToken, err := s.allocateSandboxFencingTokenLocked(
		sandbox.HostID,
		sandbox.FencingToken,
	)
	if err != nil {
		return nil, nil, false, err
	}
	storedSandbox := cloneSandboxRecord(sandbox)
	storedOperation := cloneSandboxOperation(operation)
	storedSandbox.FencingToken = fencingToken
	storedOperation.FencingToken = fencingToken
	s.sandboxes[sandbox.ID] = storedSandbox
	s.sandboxOperations[operation.ID] = storedOperation
	s.sandboxByIdempotency[idempotencyIndex] = sandbox.ID
	return cloneSandboxRecord(storedSandbox),
		cloneSandboxOperation(storedOperation),
		true,
		nil
}

func (s *MemoryStore) GetSandboxByIdempotency(
	_ context.Context,
	accountID string,
	idempotencyKey string,
) (*SandboxRecord, *SandboxOperation, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	existingID := s.sandboxByIdempotency[sandboxIdempotencyIndex(
		accountID,
		idempotencyKey,
	)]
	if existingID == "" {
		return nil, nil, ErrNotFound
	}
	sandbox := s.sandboxes[existingID]
	if sandbox == nil {
		return nil, nil, ErrSandboxConflict
	}
	for _, operation := range s.sandboxOperations {
		if operation.SandboxID == existingID &&
			operation.Kind == SandboxOperationKindPrepare {
			return cloneSandboxRecord(sandbox),
				cloneSandboxOperation(operation),
				nil
		}
	}
	return nil, nil, ErrSandboxConflict
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

func (s *MemoryStore) ListExpiringSandboxes(
	_ context.Context,
	expiresBefore time.Time,
	limit int,
) ([]SandboxRecord, error) {
	limit = sandboxListLimit(limit)
	s.mu.RLock()
	result := make([]SandboxRecord, 0)
	for _, sandbox := range s.sandboxes {
		if sandbox.ConsumesCapacity() &&
			!sandbox.LeaseExpiresAt.After(expiresBefore) {
			result = append(result, *cloneSandboxRecord(sandbox))
		}
	}
	s.mu.RUnlock()
	sort.Slice(result, func(left, right int) bool {
		return result[left].LeaseExpiresAt.Before(result[right].LeaseExpiresAt)
	})
	if len(result) > limit {
		result = result[:limit]
	}
	return result, nil
}

func (s *MemoryStore) BeginSandboxOperation(
	_ context.Context,
	operation *SandboxOperation,
	targetState string,
) (*SandboxRecord, *SandboxOperation, bool, error) {
	if err := validateSandboxOperationStart(operation, targetState); err != nil {
		return nil, nil, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	sandbox := s.sandboxes[operation.SandboxID]
	if sandbox == nil || sandbox.AccountID != operation.AccountID {
		return nil, nil, false, fmt.Errorf(
			"sandbox %s: %w",
			operation.SandboxID,
			ErrNotFound,
		)
	}
	for _, existing := range s.sandboxOperations {
		if existing.AccountID == operation.AccountID &&
			existing.SandboxID == operation.SandboxID &&
			existing.IdempotencyKey == operation.IdempotencyKey {
			return cloneSandboxRecord(sandbox),
				cloneSandboxOperation(existing),
				false,
				nil
		}
	}
	if sandbox.Generation != operation.Generation ||
		sandbox.FencingToken != operation.FencingToken ||
		sandbox.State != operation.PreviousSandboxState ||
		sandbox.Terminal() ||
		(sandbox.TerminationRequested &&
			!isSandboxTerminationOperation(operation, sandbox)) {
		return nil, nil, false, ErrSandboxConflict
	}
	if _, exists := s.sandboxOperations[operation.ID]; exists {
		return nil, nil, false, ErrSandboxConflict
	}
	for _, existing := range s.sandboxOperations {
		if existing.SandboxID == operation.SandboxID && !existing.Terminal() {
			return nil, nil, false, ErrSandboxConflict
		}
	}
	activeCommand := false
	for _, command := range s.sandboxCommands {
		if command.SandboxID == operation.SandboxID && command.Active() {
			activeCommand = true
			if !isSandboxTerminationStop(operation, sandbox) {
				return nil, nil, false, ErrSandboxConflict
			}
		}
	}
	storedOperation := cloneSandboxOperation(operation)
	if activeCommand {
		storedOperation.State = SandboxOperationQueued
		for _, command := range s.sandboxCommands {
			if command.SandboxID == operation.SandboxID && command.Active() {
				command.CancellationPending = true
				command.UpdatedAt = storedOperation.UpdatedAt
			}
		}
		s.sandboxOperations[storedOperation.ID] = storedOperation
		return cloneSandboxRecord(sandbox),
			cloneSandboxOperation(storedOperation),
			true,
			nil
	}
	if storedOperation.Kind == SandboxOperationKindRenew {
		fencingToken, err := s.allocateSandboxFencingTokenLocked(
			sandbox.HostID,
			storedOperation.RequestedFencingToken,
		)
		if err != nil {
			return nil, nil, false, err
		}
		storedOperation.RequestedFencingToken = fencingToken
	}
	sandbox.State = targetState
	if storedOperation.Kind == SandboxOperationKindDelete ||
		storedOperation.DeleteAfterStop {
		sandbox.TerminationRequested = true
	}
	sandbox.ErrorCode = ""
	sandbox.UpdatedAt = storedOperation.UpdatedAt
	s.sandboxOperations[storedOperation.ID] = storedOperation
	return cloneSandboxRecord(sandbox),
		cloneSandboxOperation(storedOperation),
		true,
		nil
}

func (s *MemoryStore) ActivateQueuedSandboxOperation(
	_ context.Context,
	operationID string,
	activatedAt time.Time,
) (*SandboxRecord, *SandboxOperation, bool, error) {
	if !validSandboxUUID(operationID) || activatedAt.IsZero() {
		return nil, nil, false, ErrSandboxInvalidTransition
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	operation := s.sandboxOperations[operationID]
	if operation == nil {
		return nil, nil, false, ErrNotFound
	}
	sandbox := s.sandboxes[operation.SandboxID]
	if sandbox == nil {
		return nil, nil, false, ErrNotFound
	}
	if operation.State != SandboxOperationQueued {
		return cloneSandboxRecord(sandbox),
			cloneSandboxOperation(operation),
			false,
			nil
	}
	if !isSandboxTerminationStop(operation, sandbox) ||
		sandbox.State != operation.PreviousSandboxState ||
		sandbox.Generation != operation.Generation ||
		sandbox.FencingToken != operation.FencingToken {
		return nil, nil, false, ErrSandboxConflict
	}
	for _, command := range s.sandboxCommands {
		if command.SandboxID == sandbox.ID && command.Active() {
			return cloneSandboxRecord(sandbox),
				cloneSandboxOperation(operation),
				false,
				nil
		}
	}
	for _, existing := range s.sandboxOperations {
		if existing.ID != operation.ID &&
			existing.SandboxID == sandbox.ID &&
			!existing.Terminal() &&
			existing.State != SandboxOperationQueued {
			return nil, nil, false, ErrSandboxConflict
		}
	}
	operation.State = SandboxOperationPending
	operation.UpdatedAt = activatedAt
	sandbox.State = SandboxStateStopping
	sandbox.ErrorCode = ""
	sandbox.UpdatedAt = activatedAt
	return cloneSandboxRecord(sandbox),
		cloneSandboxOperation(operation),
		true,
		nil
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

func (s *MemoryStore) GetSandboxOperationByIdempotency(
	_ context.Context,
	accountID string,
	sandboxID string,
	idempotencyKey string,
) (*SandboxOperation, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, operation := range s.sandboxOperations {
		if operation.AccountID == accountID &&
			operation.SandboxID == sandboxID &&
			operation.IdempotencyKey == idempotencyKey {
			return cloneSandboxOperation(operation), nil
		}
	}
	return nil, fmt.Errorf(
		"sandbox operation idempotency key: %w",
		ErrNotFound,
	)
}

func (s *MemoryStore) MarkSandboxTerminationRequested(
	_ context.Context,
	accountID string,
	sandboxID string,
	idempotencyKey string,
	at time.Time,
) (*SandboxRecord, error) {
	if !validSandboxUUID(idempotencyKey) || at.IsZero() {
		return nil, ErrSandboxInvalidTransition
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	sandbox := s.sandboxes[sandboxID]
	if sandbox == nil || sandbox.AccountID != accountID {
		return nil, fmt.Errorf("sandbox %s: %w", sandboxID, ErrNotFound)
	}
	if sandbox.TerminationIdempotencyKey != "" &&
		sandbox.TerminationIdempotencyKey != idempotencyKey {
		return nil, ErrSandboxConflict
	}
	if sandbox.Terminal() {
		return cloneSandboxRecord(sandbox), nil
	}
	sandbox.TerminationRequested = true
	if sandbox.TerminationIdempotencyKey == "" {
		sandbox.TerminationIdempotencyKey = idempotencyKey
	}
	sandbox.UpdatedAt = at
	return cloneSandboxRecord(sandbox), nil
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

func (s *MemoryStore) RecordSandboxOperationDispatch(
	_ context.Context,
	operationID string,
	dispatchedAt time.Time,
	dispatchError string,
) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	operation := s.sandboxOperations[operationID]
	if operation == nil {
		return ErrNotFound
	}
	operation.DispatchAttempts++
	operation.LastDispatchError = dispatchError
	operation.UpdatedAt = dispatchedAt
	lastDispatchedAt := dispatchedAt
	operation.LastDispatchedAt = &lastDispatchedAt
	return nil
}

func (s *MemoryStore) ListPendingSandboxOperationsByHost(
	_ context.Context,
	hostID string,
) ([]PendingSandboxOperation, error) {
	s.mu.RLock()
	result := make([]PendingSandboxOperation, 0)
	for _, operation := range s.sandboxOperations {
		sandbox := s.sandboxes[operation.SandboxID]
		if sandbox == nil ||
			sandbox.HostID != hostID ||
			operation.Terminal() {
			continue
		}
		result = append(result, PendingSandboxOperation{
			Sandbox:   *cloneSandboxRecord(sandbox),
			Operation: *cloneSandboxOperation(operation),
		})
	}
	s.mu.RUnlock()
	sort.Slice(result, func(left, right int) bool {
		return result[left].Operation.CreatedAt.Before(
			result[right].Operation.CreatedAt,
		)
	})
	return result, nil
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
	idempotencyIndex := sandboxCommandIdempotencyIndex(
		command.AccountID,
		command.SandboxID,
		command.IdempotencyKey,
	)
	if existingID := s.sandboxCommandByIdempotency[idempotencyIndex]; existingID != "" {
		return cloneSandboxCommand(s.sandboxCommands[existingID]), false, nil
	}
	if sandbox.State != SandboxStateReady ||
		sandbox.TerminationRequested ||
		sandbox.Generation != command.Generation ||
		sandbox.FencingToken != command.FencingToken ||
		command.CreatedAt.Add(
			time.Duration(command.TimeoutSeconds)*time.Second,
		).After(sandbox.LeaseExpiresAt) {
		return nil, false, ErrSandboxConflict
	}
	for _, operation := range s.sandboxOperations {
		if operation.SandboxID == command.SandboxID && !operation.Terminal() {
			return nil, false, ErrSandboxConflict
		}
	}
	for _, active := range s.sandboxCommands {
		if active.SandboxID == command.SandboxID && active.Active() {
			return nil, false, ErrSandboxConflict
		}
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

func (s *MemoryStore) ListActiveSandboxCommands(
	_ context.Context,
	sandboxID string,
) ([]SandboxCommand, error) {
	s.mu.RLock()
	result := make([]SandboxCommand, 0)
	for _, command := range s.sandboxCommands {
		if command.SandboxID == sandboxID && command.Active() {
			result = append(result, *cloneSandboxCommand(command))
		}
	}
	s.mu.RUnlock()
	sort.Slice(result, func(left, right int) bool {
		return result[left].CreatedAt.Before(result[right].CreatedAt)
	})
	return result, nil
}

func (s *MemoryStore) ListExpiringSandboxCommands(
	_ context.Context,
	expiresBefore time.Time,
	limit int,
) ([]PendingSandboxCommand, error) {
	limit = sandboxListLimit(limit)
	s.mu.RLock()
	result := make([]PendingSandboxCommand, 0)
	for _, command := range s.sandboxCommands {
		sandbox := s.sandboxes[command.SandboxID]
		if sandbox == nil ||
			command.Terminal() ||
			command.CreatedAt.Add(
				time.Duration(command.TimeoutSeconds)*time.Second,
			).After(expiresBefore) {
			continue
		}
		result = append(result, PendingSandboxCommand{
			Sandbox: *cloneSandboxRecord(sandbox),
			Command: *cloneSandboxCommand(command),
		})
	}
	s.mu.RUnlock()
	sort.Slice(result, func(left, right int) bool {
		leftDeadline := result[left].Command.CreatedAt.Add(
			time.Duration(result[left].Command.TimeoutSeconds) * time.Second,
		)
		rightDeadline := result[right].Command.CreatedAt.Add(
			time.Duration(result[right].Command.TimeoutSeconds) * time.Second,
		)
		return leftDeadline.Before(rightDeadline)
	})
	if len(result) > limit {
		result = result[:limit]
	}
	return result, nil
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

func (s *MemoryStore) RecordSandboxCommandDispatch(
	_ context.Context,
	commandID string,
	dispatchedAt time.Time,
	dispatchError string,
) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	command := s.sandboxCommands[commandID]
	if command == nil {
		return ErrNotFound
	}
	command.DispatchAttempts++
	command.LastDispatchError = dispatchError
	command.UpdatedAt = dispatchedAt
	lastDispatchedAt := dispatchedAt
	command.LastDispatchedAt = &lastDispatchedAt
	return nil
}

func (s *MemoryStore) RecordSandboxCommandCancellationDispatch(
	_ context.Context,
	commandID string,
	dispatchedAt time.Time,
	dispatchError string,
) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	command := s.sandboxCommands[commandID]
	if command == nil {
		return ErrNotFound
	}
	if !command.CancellationPending {
		return nil
	}
	command.CancelDispatchAttempts++
	command.LastCancelDispatchError = dispatchError
	command.UpdatedAt = dispatchedAt
	lastDispatchedAt := dispatchedAt
	command.LastCancelDispatchedAt = &lastDispatchedAt
	return nil
}

func (s *MemoryStore) ListPendingSandboxCommandsByHost(
	_ context.Context,
	hostID string,
) ([]PendingSandboxCommand, error) {
	s.mu.RLock()
	result := make([]PendingSandboxCommand, 0)
	for _, command := range s.sandboxCommands {
		sandbox := s.sandboxes[command.SandboxID]
		if sandbox == nil ||
			sandbox.HostID != hostID ||
			command.Terminal() {
			continue
		}
		result = append(result, PendingSandboxCommand{
			Sandbox: *cloneSandboxRecord(sandbox),
			Command: *cloneSandboxCommand(command),
		})
	}
	s.mu.RUnlock()
	sort.Slice(result, func(left, right int) bool {
		return result[left].Command.CreatedAt.Before(
			result[right].Command.CreatedAt,
		)
	})
	return result, nil
}

func (s *MemoryStore) ListPendingSandboxCommandCancellations(
	_ context.Context,
	hostIDs []string,
	limit int,
) ([]PendingSandboxCommand, error) {
	eligibleHosts := make(map[string]struct{}, len(hostIDs))
	for _, hostID := range hostIDs {
		eligibleHosts[hostID] = struct{}{}
	}
	if len(eligibleHosts) == 0 {
		return []PendingSandboxCommand{}, nil
	}
	normalizedLimit := sandboxListLimit(limit)
	s.mu.RLock()
	result := make([]PendingSandboxCommand, 0)
	for _, command := range s.sandboxCommands {
		sandbox := s.sandboxes[command.SandboxID]
		if sandbox == nil ||
			sandbox.Terminal() ||
			!command.CancellationPending {
			continue
		}
		if _, hostEligible := eligibleHosts[sandbox.HostID]; !hostEligible {
			continue
		}
		result = append(result, PendingSandboxCommand{
			Sandbox: *cloneSandboxRecord(sandbox),
			Command: *cloneSandboxCommand(command),
		})
	}
	s.mu.RUnlock()
	sort.Slice(result, func(left, right int) bool {
		return result[left].Command.CreatedAt.Before(
			result[right].Command.CreatedAt,
		)
	})
	if len(result) > normalizedLimit {
		result = result[:normalizedLimit]
	}
	return result, nil
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

func sandboxIdempotencyIndex(accountID string, idempotencyKey string) string {
	return accountID + "\x00" + idempotencyKey
}

func (s *MemoryStore) allocateSandboxFencingTokenLocked(
	hostID string,
	minimum uint64,
) (uint64, error) {
	next := s.sandboxNextFencingToken[hostID]
	if next < minimum {
		next = minimum
	}
	if next == 0 || next > maxSandboxFencingToken {
		return 0, ErrSandboxConflict
	}
	s.sandboxNextFencingToken[hostID] = next + 1
	return next, nil
}

func (s *MemoryStore) existingSandboxCreateLocked(
	existingID string,
) (*SandboxRecord, *SandboxOperation, bool, error) {
	existing := s.sandboxes[existingID]
	for _, existingOperation := range s.sandboxOperations {
		if existingOperation.SandboxID == existingID &&
			existingOperation.Kind == SandboxOperationKindPrepare {
			return cloneSandboxRecord(existing),
				cloneSandboxOperation(existingOperation),
				false,
				nil
		}
	}
	return nil, nil, false, ErrSandboxConflict
}

func validateSandboxCreate(
	sandbox *SandboxRecord,
	operation *SandboxOperation,
) error {
	if sandbox == nil || operation == nil ||
		!validSandboxUUID(sandbox.ID) ||
		sandbox.AccountID == "" ||
		!validSandboxUUID(sandbox.IdempotencyKey) ||
		!validSandboxUUID(sandbox.HostID) ||
		sandbox.Generation == 0 ||
		sandbox.FencingToken == 0 ||
		sandbox.State != SandboxStatePreparing ||
		sandbox.CreatedAt.IsZero() ||
		sandbox.UpdatedAt.IsZero() ||
		!validSandboxUUID(operation.ID) ||
		operation.SandboxID != sandbox.ID ||
		operation.AccountID != sandbox.AccountID ||
		operation.IdempotencyKey != sandbox.IdempotencyKey ||
		operation.Kind != SandboxOperationKindPrepare ||
		operation.State != SandboxOperationPending ||
		operation.Generation != sandbox.Generation ||
		operation.FencingToken != sandbox.FencingToken ||
		operation.RequestedFencingToken != 0 ||
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
		!validSandboxUUID(operation.ID) ||
		!validSandboxUUID(operation.SandboxID) ||
		operation.AccountID == "" ||
		!validSandboxUUID(operation.IdempotencyKey) ||
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
			operation.RequestedLeaseExpiresAt.IsZero() ||
			operation.RequestedFencingToken <= operation.FencingToken {
			return ErrSandboxInvalidTransition
		}
	case SandboxOperationKindStop:
		if targetState != SandboxStateStopping ||
			operation.PreviousSandboxState != SandboxStateReady ||
			operation.RequestedFencingToken != 0 {
			return ErrSandboxInvalidTransition
		}
	case SandboxOperationKindDelete:
		if targetState != SandboxStateDeleting ||
			operation.RequestedFencingToken != 0 ||
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
		!validSandboxUUID(command.ID) ||
		!validSandboxUUID(command.SandboxID) ||
		command.AccountID == "" ||
		!validSandboxUUID(command.IdempotencyKey) ||
		command.Generation == 0 ||
		command.FencingToken == 0 ||
		len(command.Arguments) == 0 ||
		command.TimeoutSeconds == 0 ||
		command.State != SandboxCommandPending ||
		command.ExitCode != nil ||
		command.StandardOutput != "" ||
		command.StandardError != "" ||
		command.OutputTruncated ||
		command.ErrorCode != "" ||
		command.DispatchAttempts != 0 ||
		command.LastDispatchedAt != nil ||
		command.LastDispatchError != "" ||
		command.CancellationPending ||
		command.CancelDispatchAttempts != 0 ||
		command.LastCancelDispatchedAt != nil ||
		command.LastCancelDispatchError != "" ||
		command.StartedAt != nil ||
		command.CompletedAt != nil ||
		command.CreatedAt.IsZero() ||
		command.UpdatedAt.IsZero() {
		return ErrSandboxInvalidTransition
	}
	return nil
}
