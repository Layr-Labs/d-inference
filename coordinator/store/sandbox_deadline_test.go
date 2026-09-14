package store

import (
	"context"
	"testing"
	"time"
)

func TestSandboxStoreLateCommandCompletionPersistsTimeout(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Date(2026, 8, 25, 10, 0, 0, 0, time.UTC)
			sandbox, prepare := sandboxFencingFixture(
				"70000000-0000-0000-0000-000000000307",
				"80000000-0000-0000-0000-000000000308",
				"90000000-0000-0000-0000-000000000309",
				uniqueID("late-command-deadline"),
				"a0000000-0000-0000-0000-000000000310",
				1,
				now,
			)
			stored, _, _, err := backend.CreateSandbox(
				ctx,
				sandbox,
				prepare,
				SandboxAllocationLimits{
					MaximumActive:     2,
					MaximumPerAccount: 2,
					MaximumPerHost:    2,
				},
			)
			if err != nil {
				t.Fatalf("create sandbox: %v", err)
			}
			if _, _, err := backend.ApplySandboxOperationUpdate(
				ctx,
				SandboxOperationUpdate{
					OperationID:  prepare.ID,
					SandboxID:    stored.ID,
					Generation:   stored.Generation,
					FencingToken: stored.FencingToken,
					State:        SandboxOperationReady,
					UpdatedAt:    now,
				},
			); err != nil {
				t.Fatalf("ready sandbox: %v", err)
			}
			command := &SandboxCommand{
				ID:             "b0000000-0000-0000-0000-000000000311",
				SandboxID:      stored.ID,
				AccountID:      stored.AccountID,
				IdempotencyKey: "c0000000-0000-0000-0000-000000000312",
				Generation:     stored.Generation,
				FencingToken:   stored.FencingToken,
				Arguments:      []string{"/usr/bin/true"},
				TimeoutSeconds: 1,
				State:          SandboxCommandPending,
				CreatedAt:      now,
				UpdatedAt:      now,
			}
			if _, created, err := backend.CreateSandboxCommand(
				ctx,
				command,
			); err != nil || !created {
				t.Fatalf("create command: created=%v error=%v", created, err)
			}

			exitCode := int32(0)
			output := "late success"
			completed, err := backend.ApplySandboxCommandUpdate(
				ctx,
				SandboxCommandUpdate{
					CommandID:      command.ID,
					SandboxID:      command.SandboxID,
					Generation:     command.Generation,
					FencingToken:   command.FencingToken,
					State:          SandboxCommandSucceeded,
					ExitCode:       &exitCode,
					StandardOutput: &output,
					UpdatedAt:      command.Deadline(),
				},
			)
			if err != nil {
				t.Fatalf("apply late command completion: %v", err)
			}
			if completed.State != SandboxCommandTimedOut ||
				completed.ErrorCode != SandboxCommandDeadlineExceeded ||
				completed.ExitCode != nil ||
				completed.StandardOutput != "" ||
				completed.StandardError != "" ||
				completed.CompletedAt == nil ||
				!completed.CompletedAt.Equal(command.Deadline()) {
				t.Fatalf("late command completion = %+v", completed)
			}
		})
	}
}
