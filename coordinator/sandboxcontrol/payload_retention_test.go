package sandboxcontrol

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func TestSandboxExpiredCommandReplayNeverRedispatches(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	backend := store.NewMemory(store.Config{})
	sandbox := createReadyTestSandbox(t, backend, now)
	controller := testSandboxController(backend, &now)
	request := CommandRequest{IdempotencyKey: uuid.NewString(), Arguments: []string{"/usr/bin/printf", "secret"}, Environment: map[string]string{"TOKEN": "secret"}, TimeoutSeconds: 60}
	command, err := controller.Execute(ctx, sandbox.AccountID, sandbox.ID, request)
	if err != nil {
		t.Fatal(err)
	}
	output, code := "secret output", int32(0)
	if _, err := backend.ApplySandboxCommandUpdate(ctx, store.SandboxCommandUpdate{CommandID: command.ID, SandboxID: command.SandboxID,
		Generation: command.Generation, FencingToken: command.FencingToken, State: store.SandboxCommandSucceeded,
		StandardOutput: &output, ExitCode: &code, UpdatedAt: now.Add(time.Second)}); err != nil {
		t.Fatal(err)
	}
	now = now.Add(23 * time.Hour)
	if err := controller.sweepCommandPayloads(ctx); err != nil {
		t.Fatal(err)
	}
	before, _ := backend.GetSandboxCommand(ctx, command.AccountID, command.SandboxID, command.ID)
	if before.PayloadExpired {
		t.Fatal("default retention redacted before24h")
	}
	now = now.Add(2 * time.Hour)
	if err := controller.sweepCommandPayloads(ctx); err != nil {
		t.Fatal(err)
	}
	replayed, err := controller.Execute(ctx, sandbox.AccountID, sandbox.ID, request)
	if err != nil || replayed.ID != command.ID || !replayed.PayloadExpired || replayed.DispatchAttempts != before.DispatchAttempts || replayed.StandardOutput != "" {
		t.Fatalf("expired replay: %+v %v", replayed, err)
	}
	request.Arguments = []string{"/usr/bin/printf", "changed"}
	if _, err := controller.Execute(ctx, sandbox.AccountID, sandbox.ID, request); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("changed expired replay error=%v", err)
	}
}
