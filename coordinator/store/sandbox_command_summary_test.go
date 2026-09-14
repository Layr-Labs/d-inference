package store

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestSandboxCommandListingThroughCachedStore(t *testing.T) {
	for name, inner := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			backend := NewCached(inner, CacheConfig{})
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Millisecond)
			sandbox, prepare := sandboxFencingFixture(uuid.NewString(), uuid.NewString(), uuid.NewString(), uniqueID("command-list"), uuid.NewString(), 1, now)
			stored, _, _, err := backend.CreateSandbox(ctx, sandbox, prepare, SandboxAllocationLimits{
				MaximumActive: 2, MaximumPerAccount: 2, MaximumPerHost: 2,
			})
			if err != nil {
				t.Fatal(err)
			}
			if _, _, err := backend.ApplySandboxOperationUpdate(ctx, SandboxOperationUpdate{
				OperationID: prepare.ID, SandboxID: stored.ID, Generation: stored.Generation,
				FencingToken: stored.FencingToken, State: SandboxOperationReady, UpdatedAt: now,
			}); err != nil {
				t.Fatal(err)
			}
			var commandIDs []string
			for index := range 3 {
				createdAt := now.Add(time.Duration(index) * time.Second)
				command := &SandboxCommand{
					ID: uuid.NewString(), SandboxID: sandbox.ID, AccountID: sandbox.AccountID, IdempotencyKey: uuid.NewString(),
					Generation: stored.Generation, FencingToken: stored.FencingToken, Arguments: []string{"/usr/bin/printf", "sensitive-argument"},
					Environment: map[string]string{"SECRET": "sensitive-environment"}, TimeoutSeconds: 60, State: SandboxCommandPending,
					CreatedAt: createdAt, UpdatedAt: createdAt,
				}
				if _, _, err := backend.CreateSandboxCommand(ctx, command); err != nil {
					t.Fatal(err)
				}
				exitCode, output := int32(0), "sensitive-output"
				if _, err := backend.ApplySandboxCommandUpdate(ctx, SandboxCommandUpdate{
					CommandID: command.ID, SandboxID: sandbox.ID, Generation: stored.Generation, FencingToken: stored.FencingToken,
					State: SandboxCommandSucceeded, ExitCode: &exitCode, StandardOutput: &output, UpdatedAt: createdAt.Add(time.Millisecond),
				}); err != nil {
					t.Fatal(err)
				}
				commandIDs = append(commandIDs, command.ID)
			}
			result, err := backend.ListSandboxCommands(ctx, sandbox.AccountID, sandbox.ID, 2)
			if err != nil || len(result) != 2 || result[0].ID != commandIDs[2] || result[1].ID != commandIDs[1] {
				t.Fatalf("bounded listing=%+v error=%v", result, err)
			}
			encoded, err := json.Marshal(result)
			if err != nil || strings.Contains(string(encoded), "sensitive-") || strings.Contains(string(encoded), "environment") || strings.Contains(string(encoded), "stdout") {
				t.Fatalf("listing contains command payload: %s %v", encoded, err)
			}
			*result[0].ExitCode = 42
			*result[0].CompletedAt = time.Time{}
			reloaded, err := backend.GetSandboxCommand(ctx, sandbox.AccountID, sandbox.ID, result[0].ID)
			if err != nil || *reloaded.ExitCode != 0 || reloaded.CompletedAt.IsZero() {
				t.Fatalf("listing exposed mutable store state: %+v %v", reloaded, err)
			}
			for _, identity := range []struct{ accountID, sandboxID string }{
				{"another-account", sandbox.ID}, {sandbox.AccountID, uuid.NewString()},
			} {
				if _, err := backend.ListSandboxCommands(ctx, identity.accountID, identity.sandboxID, 10); !errors.Is(err, ErrNotFound) {
					t.Fatalf("missing/non-owned listing error=%v", err)
				}
			}
		})
	}
}
