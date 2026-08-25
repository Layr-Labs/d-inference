package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"time"

	"github.com/google/uuid"
)

const (
	MaxSandboxListLimit    = 1000
	maxSandboxFencingToken = uint64(^uint64(0)>>1) - 1

	SandboxStatePreparing = "preparing"
	SandboxStateReady     = "ready"
	SandboxStateStopping  = "stopping"
	SandboxStateStopped   = "stopped"
	SandboxStateDeleting  = "deleting"
	SandboxStateDeleted   = "deleted"
	SandboxStateFailed    = "failed"

	SandboxOperationPending   = "pending"
	SandboxOperationQueued    = "queued"
	SandboxOperationPreparing = "preparing"
	SandboxOperationBooting   = "booting"
	SandboxOperationReady     = "ready"
	SandboxOperationStopping  = "stopping"
	SandboxOperationStopped   = "stopped"
	SandboxOperationDeleting  = "deleting"
	SandboxOperationDeleted   = "deleted"
	SandboxOperationFailed    = "failed"

	SandboxCommandPending   = "pending"
	SandboxCommandAccepted  = "accepted"
	SandboxCommandRunning   = "running"
	SandboxCommandSucceeded = "succeeded"
	SandboxCommandFailed    = "failed"
	SandboxCommandTimedOut  = "timed_out"
	SandboxCommandCancelled = "cancelled"
	SandboxCommandLost      = "lost"

	SandboxCommandDeadlineExceeded = "command_deadline_exceeded"

	SandboxOperationKindPrepare = "prepare"
	SandboxOperationKindRenew   = "renew"
	SandboxOperationKindStop    = "stop"
	SandboxOperationKindDelete  = "delete"
)

var (
	ErrSandboxConflict          = errors.New("sandbox state conflict")
	ErrSandboxInvalidTransition = errors.New("invalid sandbox state transition")
	ErrSandboxCapacity          = errors.New("sandbox capacity exhausted")
)

type SandboxRecord struct {
	ID                        string    `json:"id"`
	AccountID                 string    `json:"account_id"`
	CreatedByKeyID            string    `json:"created_by_key_id,omitempty"`
	IdempotencyKey            string    `json:"idempotency_key"`
	HostID                    string    `json:"host_id"`
	Generation                uint64    `json:"generation"`
	FencingToken              uint64    `json:"fencing_token"`
	BaseImageID               string    `json:"base_image_id"`
	CPUCount                  uint16    `json:"cpu_count"`
	MemoryBytes               uint64    `json:"memory_bytes"`
	WorkspaceBytes            uint64    `json:"workspace_bytes"`
	CommandTimeoutSeconds     uint32    `json:"command_timeout_seconds"`
	GPU                       bool      `json:"gpu"`
	State                     string    `json:"state"`
	TerminationRequested      bool      `json:"termination_requested"`
	TerminationIdempotencyKey string    `json:"termination_idempotency_key,omitempty"`
	LeaseExpiresAt            time.Time `json:"lease_expires_at"`
	ErrorCode                 string    `json:"error_code,omitempty"`
	CreatedAt                 time.Time `json:"created_at"`
	UpdatedAt                 time.Time `json:"updated_at"`
}

func (s SandboxRecord) Terminal() bool {
	return s.State == SandboxStateDeleted
}

func (s SandboxRecord) ConsumesCapacity() bool {
	return !s.Terminal()
}

func (s SandboxRecord) SameAllocationRequest(other *SandboxRecord) bool {
	if other == nil {
		return false
	}
	return s.AccountID == other.AccountID &&
		s.IdempotencyKey == other.IdempotencyKey &&
		s.BaseImageID == other.BaseImageID &&
		s.CPUCount == other.CPUCount &&
		s.MemoryBytes == other.MemoryBytes &&
		s.WorkspaceBytes == other.WorkspaceBytes &&
		s.CommandTimeoutSeconds == other.CommandTimeoutSeconds &&
		s.GPU == other.GPU
}

func (o SandboxOperation) Terminal() bool {
	switch o.State {
	case SandboxOperationReady,
		SandboxOperationStopped,
		SandboxOperationDeleted,
		SandboxOperationFailed:
		return true
	default:
		return false
	}
}

type SandboxOperation struct {
	ID                      string     `json:"id"`
	SandboxID               string     `json:"sandbox_id"`
	AccountID               string     `json:"account_id"`
	IdempotencyKey          string     `json:"idempotency_key"`
	Kind                    string     `json:"kind"`
	State                   string     `json:"state"`
	Generation              uint64     `json:"generation"`
	FencingToken            uint64     `json:"fencing_token"`
	RequestedFencingToken   uint64     `json:"requested_fencing_token,omitempty"`
	PreviousSandboxState    string     `json:"previous_sandbox_state"`
	DeleteAfterStop         bool       `json:"delete_after_stop"`
	RequestedLeaseExpiresAt time.Time  `json:"requested_lease_expires_at,omitempty"`
	ErrorCode               string     `json:"error_code,omitempty"`
	DispatchAttempts        uint32     `json:"dispatch_attempts"`
	LastDispatchedAt        *time.Time `json:"last_dispatched_at,omitempty"`
	LastDispatchError       string     `json:"last_dispatch_error,omitempty"`
	CreatedAt               time.Time  `json:"created_at"`
	UpdatedAt               time.Time  `json:"updated_at"`
}

func (o SandboxOperation) SameRequest(other *SandboxOperation) bool {
	if other == nil {
		return false
	}
	return o.SandboxID == other.SandboxID &&
		o.AccountID == other.AccountID &&
		o.IdempotencyKey == other.IdempotencyKey &&
		o.Kind == other.Kind &&
		o.DeleteAfterStop == other.DeleteAfterStop
}

func isSandboxTerminationStop(
	operation *SandboxOperation,
	sandbox *SandboxRecord,
) bool {
	return operation != nil &&
		sandbox != nil &&
		operation.Kind == SandboxOperationKindStop &&
		operation.DeleteAfterStop &&
		sandbox.TerminationRequested
}

func isSandboxTerminationOperation(
	operation *SandboxOperation,
	sandbox *SandboxRecord,
) bool {
	if operation == nil || sandbox == nil || !sandbox.TerminationRequested {
		return false
	}
	switch operation.Kind {
	case SandboxOperationKindStop:
		return operation.DeleteAfterStop
	case SandboxOperationKindDelete:
		return true
	default:
		return false
	}
}

type SandboxOperationUpdate struct {
	OperationID    string
	SandboxID      string
	Generation     uint64
	FencingToken   uint64
	State          string
	ErrorCode      string
	LeaseExpiresAt *time.Time
	UpdatedAt      time.Time
}

type SandboxCommand struct {
	ID                      string            `json:"id"`
	SandboxID               string            `json:"sandbox_id"`
	AccountID               string            `json:"account_id"`
	IdempotencyKey          string            `json:"idempotency_key"`
	Generation              uint64            `json:"generation"`
	FencingToken            uint64            `json:"fencing_token"`
	Arguments               []string          `json:"arguments"`
	Environment             map[string]string `json:"environment,omitempty"`
	WorkingDirectory        string            `json:"working_directory,omitempty"`
	TimeoutSeconds          uint32            `json:"timeout_seconds"`
	State                   string            `json:"state"`
	ExitCode                *int32            `json:"exit_code,omitempty"`
	StandardOutput          string            `json:"stdout,omitempty"`
	StandardError           string            `json:"stderr,omitempty"`
	OutputTruncated         bool              `json:"output_truncated"`
	ErrorCode               string            `json:"error_code,omitempty"`
	DispatchAttempts        uint32            `json:"dispatch_attempts"`
	LastDispatchedAt        *time.Time        `json:"last_dispatched_at,omitempty"`
	LastDispatchError       string            `json:"last_dispatch_error,omitempty"`
	CancellationPending     bool              `json:"cancellation_pending"`
	CancelDispatchAttempts  uint32            `json:"cancel_dispatch_attempts"`
	LastCancelDispatchedAt  *time.Time        `json:"last_cancel_dispatched_at,omitempty"`
	LastCancelDispatchError string            `json:"last_cancel_dispatch_error,omitempty"`
	CreatedAt               time.Time         `json:"created_at"`
	StartedAt               *time.Time        `json:"started_at,omitempty"`
	CompletedAt             *time.Time        `json:"completed_at,omitempty"`
	UpdatedAt               time.Time         `json:"updated_at"`
}

func (c SandboxCommand) Terminal() bool {
	switch c.State {
	case SandboxCommandSucceeded,
		SandboxCommandFailed,
		SandboxCommandTimedOut,
		SandboxCommandCancelled,
		SandboxCommandLost:
		return true
	default:
		return false
	}
}

func (c SandboxCommand) Active() bool {
	return !c.Terminal() || c.CancellationPending
}

func (c SandboxCommand) SameRequest(other *SandboxCommand) bool {
	if other == nil {
		return false
	}
	return c.SandboxID == other.SandboxID &&
		c.AccountID == other.AccountID &&
		c.IdempotencyKey == other.IdempotencyKey &&
		c.TimeoutSeconds == other.TimeoutSeconds &&
		c.WorkingDirectory == other.WorkingDirectory &&
		reflect.DeepEqual(c.Arguments, other.Arguments) &&
		reflect.DeepEqual(c.Environment, other.Environment)
}

func (c SandboxCommand) Deadline() time.Time {
	return c.CreatedAt.Add(time.Duration(c.TimeoutSeconds) * time.Second)
}

func (c SandboxCommand) DeadlineReached(at time.Time) bool {
	return !at.Before(c.Deadline())
}

type SandboxCommandUpdate struct {
	CommandID           string
	SandboxID           string
	Generation          uint64
	FencingToken        uint64
	State               string
	ExitCode            *int32
	StandardOutput      *string
	StandardError       *string
	OutputTruncated     bool
	ErrorCode           string
	RequestCancellation bool
	UpdatedAt           time.Time
}

type SandboxAllocationLimits struct {
	MaximumActive     int
	MaximumPerAccount int
	MaximumPerHost    int
}

type PendingSandboxOperation struct {
	Sandbox   SandboxRecord
	Operation SandboxOperation
}

type PendingSandboxCommand struct {
	Sandbox SandboxRecord
	Command SandboxCommand
}

func cloneSandboxRecord(record *SandboxRecord) *SandboxRecord {
	if record == nil {
		return nil
	}
	cloned := *record
	return &cloned
}

func cloneSandboxOperation(operation *SandboxOperation) *SandboxOperation {
	if operation == nil {
		return nil
	}
	cloned := *operation
	if operation.LastDispatchedAt != nil {
		lastDispatchedAt := *operation.LastDispatchedAt
		cloned.LastDispatchedAt = &lastDispatchedAt
	}
	return &cloned
}

func cloneSandboxCommand(command *SandboxCommand) *SandboxCommand {
	if command == nil {
		return nil
	}
	cloned := *command
	cloned.Arguments = append([]string(nil), command.Arguments...)
	if command.Environment != nil {
		cloned.Environment = make(map[string]string, len(command.Environment))
		for key, value := range command.Environment {
			cloned.Environment[key] = value
		}
	}
	if command.ExitCode != nil {
		exitCode := *command.ExitCode
		cloned.ExitCode = &exitCode
	}
	if command.StartedAt != nil {
		startedAt := *command.StartedAt
		cloned.StartedAt = &startedAt
	}
	if command.CompletedAt != nil {
		completedAt := *command.CompletedAt
		cloned.CompletedAt = &completedAt
	}
	if command.LastDispatchedAt != nil {
		lastDispatchedAt := *command.LastDispatchedAt
		cloned.LastDispatchedAt = &lastDispatchedAt
	}
	if command.LastCancelDispatchedAt != nil {
		lastCancelDispatchedAt := *command.LastCancelDispatchedAt
		cloned.LastCancelDispatchedAt = &lastCancelDispatchedAt
	}
	return &cloned
}

func sandboxCommandJSON(command *SandboxCommand) ([]byte, []byte, error) {
	arguments, err := json.Marshal(command.Arguments)
	if err != nil {
		return nil, nil, err
	}
	environment, err := json.Marshal(command.Environment)
	if err != nil {
		return nil, nil, err
	}
	return arguments, environment, nil
}

func applySandboxOperationTransition(
	sandbox *SandboxRecord,
	operation *SandboxOperation,
	update SandboxOperationUpdate,
) error {
	if sandbox == nil || operation == nil ||
		operation.ID != update.OperationID ||
		operation.SandboxID != update.SandboxID ||
		sandbox.ID != update.SandboxID ||
		operation.Generation != update.Generation ||
		sandbox.Generation != update.Generation {
		return ErrSandboxConflict
	}
	if operation.Terminal() {
		if sandboxOperationReplayEquivalent(sandbox, operation, update) {
			return nil
		}
		return ErrSandboxConflict
	}
	if operation.FencingToken != sandbox.FencingToken {
		return ErrSandboxConflict
	}
	if update.UpdatedAt.IsZero() {
		return fmt.Errorf("%w: missing update time", ErrSandboxInvalidTransition)
	}
	if !validSandboxOperationTransition(
		operation.Kind,
		operation.State,
		update.State,
	) {
		return ErrSandboxInvalidTransition
	}

	switch operation.Kind {
	case SandboxOperationKindRenew:
		if update.State == SandboxOperationFailed {
			if update.FencingToken != sandbox.FencingToken {
				return ErrSandboxConflict
			}
		} else {
			if operation.RequestedFencingToken == 0 {
				if update.FencingToken <= sandbox.FencingToken {
					return ErrSandboxConflict
				}
			} else {
				if operation.RequestedFencingToken <= sandbox.FencingToken ||
					update.FencingToken != operation.RequestedFencingToken {
					return ErrSandboxConflict
				}
			}
			if update.LeaseExpiresAt == nil ||
				update.LeaseExpiresAt.Before(sandbox.LeaseExpiresAt) {
				return ErrSandboxInvalidTransition
			}
			sandbox.FencingToken = update.FencingToken
			sandbox.LeaseExpiresAt = *update.LeaseExpiresAt
			sandbox.State = operation.PreviousSandboxState
			sandbox.ErrorCode = ""
		}
	default:
		if update.FencingToken != sandbox.FencingToken {
			return ErrSandboxConflict
		}
		sandbox.State = sandboxStateForOperationUpdate(operation, update.State)
		if update.State == SandboxOperationFailed {
			sandbox.ErrorCode = update.ErrorCode
		} else {
			sandbox.ErrorCode = ""
		}
	}
	if update.State == SandboxOperationFailed &&
		operation.Kind == SandboxOperationKindRenew {
		sandbox.State = operation.PreviousSandboxState
		sandbox.ErrorCode = update.ErrorCode
	}
	sandbox.UpdatedAt = update.UpdatedAt
	operation.State = update.State
	operation.ErrorCode = update.ErrorCode
	operation.UpdatedAt = update.UpdatedAt
	return nil
}

func sandboxOperationReplayEquivalent(
	sandbox *SandboxRecord,
	operation *SandboxOperation,
	update SandboxOperationUpdate,
) bool {
	if operation.State != update.State ||
		operation.ErrorCode != update.ErrorCode {
		return false
	}
	if operation.Kind == SandboxOperationKindRenew &&
		update.State != SandboxOperationFailed {
		return update.FencingToken == sandbox.FencingToken &&
			update.LeaseExpiresAt != nil &&
			update.LeaseExpiresAt.Equal(sandbox.LeaseExpiresAt)
	}
	return update.FencingToken == sandbox.FencingToken
}

func validSandboxOperationTransition(kind, from, to string) bool {
	if from == to {
		return true
	}
	switch kind {
	case SandboxOperationKindPrepare:
		switch from {
		case SandboxOperationPending:
			return to == SandboxOperationPreparing ||
				to == SandboxOperationBooting ||
				to == SandboxOperationReady ||
				to == SandboxOperationFailed
		case SandboxOperationPreparing:
			return to == SandboxOperationBooting ||
				to == SandboxOperationReady ||
				to == SandboxOperationFailed
		case SandboxOperationBooting:
			return to == SandboxOperationReady ||
				to == SandboxOperationFailed
		}
	case SandboxOperationKindRenew:
		return from == SandboxOperationPending &&
			(to == SandboxOperationReady ||
				to == SandboxOperationStopped ||
				to == SandboxOperationFailed)
	case SandboxOperationKindStop:
		switch from {
		case SandboxOperationPending:
			return to == SandboxOperationStopping ||
				to == SandboxOperationStopped ||
				to == SandboxOperationFailed
		case SandboxOperationStopping:
			return to == SandboxOperationStopped ||
				to == SandboxOperationFailed
		}
	case SandboxOperationKindDelete:
		switch from {
		case SandboxOperationPending:
			return to == SandboxOperationDeleting ||
				to == SandboxOperationDeleted ||
				to == SandboxOperationFailed
		case SandboxOperationDeleting:
			return to == SandboxOperationDeleted ||
				to == SandboxOperationFailed
		}
	}
	return false
}

func sandboxStateForOperationUpdate(
	operation *SandboxOperation,
	state string,
) string {
	if state == SandboxOperationFailed {
		if operation.Kind == SandboxOperationKindPrepare {
			return SandboxStateFailed
		}
		return operation.PreviousSandboxState
	}
	switch operation.Kind {
	case SandboxOperationKindPrepare:
		switch state {
		case SandboxOperationReady:
			return SandboxStateReady
		case SandboxOperationPreparing, SandboxOperationBooting:
			return SandboxStatePreparing
		}
	case SandboxOperationKindStop:
		if state == SandboxOperationStopped {
			return SandboxStateStopped
		}
		return SandboxStateStopping
	case SandboxOperationKindDelete:
		if state == SandboxOperationDeleted {
			return SandboxStateDeleted
		}
		return SandboxStateDeleting
	}
	return operation.PreviousSandboxState
}

func applySandboxCommandTransition(
	command *SandboxCommand,
	update SandboxCommandUpdate,
) error {
	if command == nil ||
		command.ID != update.CommandID ||
		command.SandboxID != update.SandboxID ||
		command.Generation != update.Generation ||
		command.FencingToken != update.FencingToken {
		return ErrSandboxConflict
	}
	if update.UpdatedAt.IsZero() {
		return fmt.Errorf("%w: missing update time", ErrSandboxInvalidTransition)
	}
	if command.Terminal() {
		if command.CancellationPending &&
			isTerminalSandboxCommandState(update.State) {
			command.CancellationPending = false
			command.UpdatedAt = update.UpdatedAt
			return nil
		}
		if sandboxCommandReplayEquivalent(command, update) {
			return nil
		}
		return ErrSandboxInvalidTransition
	}
	reportedTerminal := isTerminalSandboxCommandState(update.State)
	requestCancellation := update.RequestCancellation
	if command.DeadlineReached(update.UpdatedAt) {
		requestCancellation = requestCancellation || !reportedTerminal
		empty := ""
		update.State = SandboxCommandTimedOut
		update.ExitCode = nil
		update.StandardOutput = &empty
		update.StandardError = &empty
		update.OutputTruncated = false
		update.ErrorCode = SandboxCommandDeadlineExceeded
	}
	if !validSandboxCommandTransition(command.State, update.State) {
		return ErrSandboxInvalidTransition
	}
	command.State = update.State
	command.ExitCode = cloneInt32(update.ExitCode)
	if update.StandardOutput != nil {
		command.StandardOutput = *update.StandardOutput
	}
	if update.StandardError != nil {
		command.StandardError = *update.StandardError
	}
	command.OutputTruncated = update.OutputTruncated
	command.ErrorCode = update.ErrorCode
	command.UpdatedAt = update.UpdatedAt
	if reportedTerminal {
		command.CancellationPending = false
	}
	if requestCancellation {
		command.CancellationPending = true
	}
	if update.State == SandboxCommandRunning && command.StartedAt == nil {
		startedAt := update.UpdatedAt
		command.StartedAt = &startedAt
	}
	if command.Terminal() {
		completedAt := update.UpdatedAt
		command.CompletedAt = &completedAt
	}
	return nil
}

func sandboxCommandReplayEquivalent(
	command *SandboxCommand,
	update SandboxCommandUpdate,
) bool {
	if command.State != update.State ||
		command.ErrorCode != update.ErrorCode ||
		command.OutputTruncated != update.OutputTruncated ||
		!equalOptionalInt32(command.ExitCode, update.ExitCode) {
		return false
	}
	if update.StandardOutput == nil {
		if command.StandardOutput != "" {
			return false
		}
	} else if command.StandardOutput != *update.StandardOutput {
		return false
	}
	if update.StandardError == nil {
		return command.StandardError == ""
	}
	return command.StandardError == *update.StandardError
}

func equalOptionalInt32(left, right *int32) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return *left == *right
}

func validSandboxUUID(value string) bool {
	if len(value) != 36 ||
		value[8] != '-' ||
		value[13] != '-' ||
		value[18] != '-' ||
		value[23] != '-' {
		return false
	}
	_, err := uuid.Parse(value)
	return err == nil
}

func validSandboxCommandTransition(from, to string) bool {
	if from == to {
		return true
	}
	switch from {
	case SandboxCommandPending:
		return to == SandboxCommandAccepted ||
			to == SandboxCommandRunning ||
			isTerminalSandboxCommandState(to)
	case SandboxCommandAccepted:
		return to == SandboxCommandRunning ||
			isTerminalSandboxCommandState(to)
	case SandboxCommandRunning:
		return isTerminalSandboxCommandState(to)
	default:
		return false
	}
}

func isTerminalSandboxCommandState(state string) bool {
	switch state {
	case SandboxCommandSucceeded,
		SandboxCommandFailed,
		SandboxCommandTimedOut,
		SandboxCommandCancelled,
		SandboxCommandLost:
		return true
	default:
		return false
	}
}

func cloneInt32(value *int32) *int32 {
	if value == nil {
		return nil
	}
	cloned := *value
	return &cloned
}
