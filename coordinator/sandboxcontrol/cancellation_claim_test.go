package sandboxcontrol

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestCancellationDispatchPersistsClaimBeforeFastFailureCanRedispatch(
	t *testing.T,
) {
	ctx := context.Background()
	now := time.Date(2026, 8, 25, 19, 0, 0, 0, time.UTC)
	backend := store.NewMemory(store.Config{})
	sandbox := createReadyTestSandbox(t, backend, now)
	command := &store.SandboxCommand{
		ID:             "91000000-0000-0000-0000-000000000191",
		SandboxID:      sandbox.ID,
		AccountID:      sandbox.AccountID,
		IdempotencyKey: "92000000-0000-0000-0000-000000000192",
		Generation:     sandbox.Generation,
		FencingToken:   sandbox.FencingToken,
		Arguments:      []string{"/usr/bin/sleep", "900"},
		TimeoutSeconds: CommandTimeoutSeconds,
		State:          store.SandboxCommandPending,
		CreatedAt:      now,
		UpdatedAt:      now,
	}
	if _, created, err := backend.CreateSandboxCommand(ctx, command); err != nil ||
		!created {
		t.Fatalf("create command: created=%v error=%v", created, err)
	}
	timedOut, err := backend.ApplySandboxCommandUpdate(
		ctx,
		store.SandboxCommandUpdate{
			CommandID:           command.ID,
			SandboxID:           command.SandboxID,
			Generation:          command.Generation,
			FencingToken:        command.FencingToken,
			State:               store.SandboxCommandTimedOut,
			ErrorCode:           store.SandboxCommandDeadlineExceeded,
			RequestCancellation: true,
			UpdatedAt:           now.Add(time.Second),
		},
	)
	if err != nil {
		t.Fatalf("persist timeout cancellation: %v", err)
	}

	completionStarted := make(chan struct{})
	releaseCompletion := make(chan struct{})
	wrapped := &blockingCancellationCompletionStore{
		SandboxStore:      backend,
		completionStarted: completionStarted,
		releaseCompletion: releaseCompletion,
	}
	hosts := sandboxhost.NewRegistry(nil)
	transport := &cancellationTestTransport{}
	session := registerCancellationTestHost(
		t,
		hosts,
		sandbox,
		"93000000-0000-0000-0000-000000000193",
		transport,
	)
	controller := &Controller{
		store:           wrapped,
		hosts:           hosts,
		now:             func() time.Time { return now.Add(2 * time.Second) },
		hostNextFence:   make(map[string]uint64),
		reconciledEpoch: make(map[string]string),
	}

	dispatchResult := make(chan error, 1)
	go func() {
		dispatchResult <- controller.dispatchCommandCancellation(
			ctx,
			sandbox,
			timedOut,
		)
	}()
	<-completionStarted

	if err := controller.forceDispatchCommandCancellation(
		ctx,
		sandbox,
		timedOut,
	); err != nil {
		t.Fatalf("concurrent stale cancellation claim should deduplicate: %v", err)
	}
	if frames := transport.frames(); len(frames) != 1 {
		t.Fatalf("stale cancellation claim sent %d frames, want 1", len(frames))
	}

	commandID := command.ID
	scope := protocol.SandboxScope{
		SandboxID:    command.SandboxID,
		Generation:   command.Generation,
		FencingToken: command.FencingToken,
	}
	handlerErr := controller.handleHostFailure(
		ctx,
		session,
		&protocol.SandboxHostFailurePayload{
			CommandID: &commandID,
			Scope:     &scope,
			ErrorCode: runtimeCleanupFailedErrorCode,
		},
	)
	framesBeforeRelease := len(transport.frames())
	close(releaseCompletion)
	dispatchErr := <-dispatchResult

	if handlerErr != nil {
		t.Fatalf("handle fast cancellation failure: %v", handlerErr)
	}
	if dispatchErr != nil {
		t.Fatalf("dispatch cancellation: %v", dispatchErr)
	}
	if framesBeforeRelease != 1 {
		t.Fatalf(
			"fast failure redispatched before the first claim persisted: frames=%d want=1",
			framesBeforeRelease,
		)
	}
}

type blockingCancellationCompletionStore struct {
	store.SandboxStore
	completionStarted chan struct{}
	releaseCompletion chan struct{}
	once              sync.Once
}

func (s *blockingCancellationCompletionStore) CompleteSandboxCommandCancellationDispatch(
	ctx context.Context,
	commandID string,
	attempt uint32,
	dispatchError string,
) (bool, error) {
	blocked := false
	s.once.Do(func() {
		blocked = true
		close(s.completionStarted)
	})
	if blocked {
		<-s.releaseCompletion
	}
	return s.SandboxStore.CompleteSandboxCommandCancellationDispatch(
		ctx,
		commandID,
		attempt,
		dispatchError,
	)
}
