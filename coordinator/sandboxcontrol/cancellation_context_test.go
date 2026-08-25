package sandboxcontrol

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestCancellationDispatchCanceledCallerDoesNotClaim(t *testing.T) {
	now := time.Date(2026, 8, 25, 19, 30, 0, 0, time.UTC)
	pending := cancellationContextPending(
		now,
		"91000000-0000-0000-0000-000000000291",
		"92000000-0000-0000-0000-000000000292",
		"93000000-0000-0000-0000-000000000293",
	)
	backend := &contextAwareCancellationStore{
		pending: []store.PendingSandboxCommand{pending},
	}
	hosts := sandboxhost.NewRegistry(nil)
	transport := &cancellationTestTransport{}
	_ = registerCancellationTestHost(
		t,
		hosts,
		&pending.Sandbox,
		"94000000-0000-0000-0000-000000000294",
		transport,
	)
	controller := &Controller{
		store:           backend,
		hosts:           hosts,
		now:             func() time.Time { return now },
		hostNextFence:   make(map[string]uint64),
		reconciledEpoch: make(map[string]string),
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	err := controller.dispatchCommandCancellation(
		ctx,
		&pending.Sandbox,
		&pending.Command,
	)

	if !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled caller error = %v, want context canceled", err)
	}
	stored := backend.command(pending.Command.ID)
	if stored == nil ||
		stored.CancelDispatchAttempts != 0 ||
		stored.LastCancelDispatchedAt != nil {
		t.Fatalf("canceled caller claimed cancellation: %+v", stored)
	}
	if frames := transport.frames(); len(frames) != 0 {
		t.Fatalf("canceled caller sent %d cancellation frames", len(frames))
	}
}

func TestCancellationDispatchJoinsSendAndCompletionErrors(t *testing.T) {
	now := time.Date(2026, 8, 25, 19, 45, 0, 0, time.UTC)
	pending := cancellationContextPending(
		now,
		"95000000-0000-0000-0000-000000000295",
		"96000000-0000-0000-0000-000000000296",
		"97000000-0000-0000-0000-000000000297",
	)
	backend := &contextAwareCancellationStore{
		pending: []store.PendingSandboxCommand{pending},
	}
	sendErr := errors.New("injected cancellation send failure")
	completionErr := errors.New("injected cancellation completion failure")
	wrapped := &failingCancellationCompletionStore{
		SandboxStore: backend,
		err:          completionErr,
	}
	hosts := sandboxhost.NewRegistry(nil)
	_ = registerCancellationTestHost(
		t,
		hosts,
		&pending.Sandbox,
		"98000000-0000-0000-0000-000000000298",
		&fixedErrorCancellationTransport{err: sendErr},
	)
	controller := &Controller{
		store:           wrapped,
		hosts:           hosts,
		now:             func() time.Time { return now },
		hostNextFence:   make(map[string]uint64),
		reconciledEpoch: make(map[string]string),
	}

	err := controller.dispatchCommandCancellation(
		context.Background(),
		&pending.Sandbox,
		&pending.Command,
	)

	if !errors.Is(err, sendErr) || !errors.Is(err, completionErr) {
		t.Fatalf(
			"combined cancellation error = %v, want send and completion errors",
			err,
		)
	}
	stored := backend.command(pending.Command.ID)
	if stored == nil ||
		stored.CancelDispatchAttempts != 1 ||
		stored.LastCancelDispatchedAt == nil {
		t.Fatalf("failed completion did not retain claim rotation: %+v", stored)
	}
}

func TestCancellationDispatchExpiredSendContextStillRotatesBoundedBatch(
	t *testing.T,
) {
	now := time.Date(2026, 8, 25, 20, 0, 0, 0, time.UTC)
	hostID := "94000000-0000-0000-0000-000000000194"
	pending := make([]store.PendingSandboxCommand, 0, cancellationSweepBatchLimit+1)
	for index := 0; index < cancellationSweepBatchLimit+1; index++ {
		sandboxID := fmt.Sprintf(
			"95000000-0000-0000-0000-%012d",
			index+1,
		)
		commandID := fmt.Sprintf(
			"96000000-0000-0000-0000-%012d",
			index+1,
		)
		pending = append(pending, store.PendingSandboxCommand{
			Sandbox: store.SandboxRecord{
				ID:             sandboxID,
				HostID:         hostID,
				Generation:     1,
				FencingToken:   10,
				BaseImageID:    "macos-tahoe-v1",
				CPUCount:       4,
				MemoryBytes:    8 << 30,
				WorkspaceBytes: 25 << 30,
				State:          store.SandboxStateReady,
			},
			Command: store.SandboxCommand{
				ID:                  commandID,
				SandboxID:           sandboxID,
				Generation:          1,
				FencingToken:        10,
				State:               store.SandboxCommandTimedOut,
				CancellationPending: true,
				CreatedAt:           now.Add(time.Duration(index) * time.Second),
				UpdatedAt:           now.Add(time.Duration(index) * time.Second),
			},
		})
	}
	backend := &contextAwareCancellationStore{pending: pending}
	hosts := sandboxhost.NewRegistry(nil)
	expired := newTriggeredDeadlineContext()
	transport := &expiringCancellationTransport{expire: expired.expire}
	first := pending[0]
	_ = registerCancellationTestHost(
		t,
		hosts,
		&first.Sandbox,
		"97000000-0000-0000-0000-000000000197",
		transport,
	)
	controller := &Controller{
		store:           backend,
		hosts:           hosts,
		now:             func() time.Time { return now.Add(time.Hour) },
		hostNextFence:   make(map[string]uint64),
		reconciledEpoch: make(map[string]string),
	}

	err := controller.dispatchCommandCancellation(
		expired,
		&first.Sandbox,
		&first.Command,
	)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expired send error = %v, want deadline exceeded", err)
	}
	rotated, listErr := backend.ListPendingSandboxCommandCancellations(
		context.Background(),
		[]string{hostID},
		cancellationSweepBatchLimit,
	)
	if listErr != nil {
		t.Fatalf("list bounded cancellation batch: %v", listErr)
	}
	tailID := pending[len(pending)-1].Command.ID
	tailIncluded := false
	for index := range rotated {
		if rotated[index].Command.ID == tailID {
			tailIncluded = true
			break
		}
	}
	firstAfter := backend.command(first.Command.ID)
	if firstAfter == nil || firstAfter.LastCancelDispatchedAt == nil {
		t.Fatal("expired send left the claimed row timestamp NULL")
	}
	if firstAfter.LastCancelDispatchError != "dispatch_failed" {
		t.Fatalf(
			"expired send completion error = %q, want dispatch_failed",
			firstAfter.LastCancelDispatchError,
		)
	}
	if !tailIncluded {
		t.Fatalf(
			"expired send monopolized bounded batch; tail command %s was excluded",
			tailID,
		)
	}
}

type contextAwareCancellationStore struct {
	store.SandboxStore
	mu      sync.Mutex
	pending []store.PendingSandboxCommand
}

type failingCancellationCompletionStore struct {
	store.SandboxStore
	err error
}

func (s *failingCancellationCompletionStore) CompleteSandboxCommandCancellationDispatch(
	context.Context,
	string,
	uint32,
	string,
) (bool, error) {
	return false, s.err
}

func (s *contextAwareCancellationStore) ClaimSandboxCommandCancellationDispatch(
	ctx context.Context,
	commandID string,
	expectedAttempts uint32,
	retryCutoff time.Time,
	dispatchedAt time.Time,
) (uint32, bool, error) {
	if err := ctx.Err(); err != nil {
		return 0, false, err
	}
	if _, bounded := ctx.Deadline(); !bounded {
		return 0, false, errors.New("claim persistence context is unbounded")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for index := range s.pending {
		command := &s.pending[index].Command
		if command.ID != commandID {
			continue
		}
		if !command.CancellationPending ||
			command.CancelDispatchAttempts != expectedAttempts ||
			(command.LastCancelDispatchedAt != nil &&
				command.LastCancelDispatchedAt.After(retryCutoff)) {
			return 0, false, nil
		}
		command.CancelDispatchAttempts++
		command.LastCancelDispatchError = ""
		attemptedAt := dispatchedAt
		command.LastCancelDispatchedAt = &attemptedAt
		command.UpdatedAt = dispatchedAt
		return command.CancelDispatchAttempts, true, nil
	}
	return 0, false, nil
}

func (s *contextAwareCancellationStore) CompleteSandboxCommandCancellationDispatch(
	ctx context.Context,
	commandID string,
	attempt uint32,
	dispatchError string,
) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if _, bounded := ctx.Deadline(); !bounded {
		return false, errors.New(
			"completion persistence context is unbounded",
		)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for index := range s.pending {
		command := &s.pending[index].Command
		if command.ID != commandID {
			continue
		}
		if !command.CancellationPending ||
			command.CancelDispatchAttempts != attempt {
			return false, nil
		}
		command.LastCancelDispatchError = dispatchError
		return true, nil
	}
	return false, nil
}

func (s *contextAwareCancellationStore) ListPendingSandboxCommandCancellations(
	ctx context.Context,
	hostIDs []string,
	limit int,
) ([]store.PendingSandboxCommand, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	eligibleHosts := make(map[string]struct{}, len(hostIDs))
	for _, hostID := range hostIDs {
		eligibleHosts[hostID] = struct{}{}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make([]store.PendingSandboxCommand, 0, len(s.pending))
	for index := range s.pending {
		pending := s.pending[index]
		if _, exists := eligibleHosts[pending.Sandbox.HostID]; !exists ||
			!pending.Command.CancellationPending {
			continue
		}
		result = append(result, clonePendingCancellation(pending))
	}
	sort.Slice(result, func(left, right int) bool {
		leftAttempt := result[left].Command.LastCancelDispatchedAt
		rightAttempt := result[right].Command.LastCancelDispatchedAt
		if leftAttempt == nil || rightAttempt == nil {
			return leftAttempt == nil && rightAttempt != nil
		}
		if !leftAttempt.Equal(*rightAttempt) {
			return leftAttempt.Before(*rightAttempt)
		}
		return result[left].Command.CreatedAt.Before(
			result[right].Command.CreatedAt,
		)
	})
	if limit <= 0 || limit > store.MaxSandboxListLimit {
		limit = store.MaxSandboxListLimit
	}
	if len(result) > limit {
		result = result[:limit]
	}
	return result, nil
}

func (s *contextAwareCancellationStore) command(
	commandID string,
) *store.SandboxCommand {
	s.mu.Lock()
	defer s.mu.Unlock()
	for index := range s.pending {
		if s.pending[index].Command.ID == commandID {
			command := s.pending[index].Command
			if command.LastCancelDispatchedAt != nil {
				attemptedAt := *command.LastCancelDispatchedAt
				command.LastCancelDispatchedAt = &attemptedAt
			}
			return &command
		}
	}
	return nil
}

func clonePendingCancellation(
	pending store.PendingSandboxCommand,
) store.PendingSandboxCommand {
	cloned := pending
	if pending.Command.LastCancelDispatchedAt != nil {
		attemptedAt := *pending.Command.LastCancelDispatchedAt
		cloned.Command.LastCancelDispatchedAt = &attemptedAt
	}
	return cloned
}

type triggeredDeadlineContext struct {
	context.Context
	done chan struct{}
	once sync.Once
}

func newTriggeredDeadlineContext() *triggeredDeadlineContext {
	return &triggeredDeadlineContext{
		Context: context.Background(),
		done:    make(chan struct{}),
	}
}

func (c *triggeredDeadlineContext) Done() <-chan struct{} {
	return c.done
}

func (c *triggeredDeadlineContext) Err() error {
	select {
	case <-c.done:
		return context.DeadlineExceeded
	default:
		return nil
	}
}

func (c *triggeredDeadlineContext) expire() {
	c.once.Do(func() {
		close(c.done)
	})
}

type expiringCancellationTransport struct {
	expire func()
}

func (t *expiringCancellationTransport) Write(
	ctx context.Context,
	_ []byte,
) error {
	t.expire()
	return ctx.Err()
}

func (t *expiringCancellationTransport) Close(string) error {
	return nil
}

type fixedErrorCancellationTransport struct {
	err error
}

func (t *fixedErrorCancellationTransport) Write(
	context.Context,
	[]byte,
) error {
	return t.err
}

func (t *fixedErrorCancellationTransport) Close(string) error {
	return nil
}

func cancellationContextPending(
	now time.Time,
	hostID string,
	sandboxID string,
	commandID string,
) store.PendingSandboxCommand {
	return store.PendingSandboxCommand{
		Sandbox: store.SandboxRecord{
			ID:             sandboxID,
			HostID:         hostID,
			Generation:     1,
			FencingToken:   10,
			BaseImageID:    "macos-tahoe-v1",
			CPUCount:       4,
			MemoryBytes:    8 << 30,
			WorkspaceBytes: 25 << 30,
			State:          store.SandboxStateReady,
		},
		Command: store.SandboxCommand{
			ID:                  commandID,
			SandboxID:           sandboxID,
			Generation:          1,
			FencingToken:        10,
			State:               store.SandboxCommandTimedOut,
			CancellationPending: true,
			CreatedAt:           now,
			UpdatedAt:           now,
		},
	}
}
