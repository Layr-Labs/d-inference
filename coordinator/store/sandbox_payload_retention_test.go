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

func TestSandboxPayloadRetentionPreservesReplayAndExcludesActiveWork(t *testing.T) {
	for name, inner := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			backend := NewCached(inner, CacheConfig{})
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Millisecond)
			old := now.Add(-48 * time.Hour)
			sandbox := retentionSandbox(t, backend, now)
			first := retentionCommand(t, backend, sandbox, old, SandboxCommandSucceeded, false)
			second := retentionCommand(t, backend, sandbox, old.Add(time.Minute), SandboxCommandFailed, false)
			recent := retentionCommand(t, backend, sandbox, now.Add(-time.Hour), SandboxCommandSucceeded, false)
			cancelling := retentionCommand(t, backend, sandbox, old.Add(2*time.Minute), SandboxCommandCancelled, true)
			otherSandbox := retentionSandbox(t, backend, now)
			active := retentionCommand(t, backend, otherSandbox, old, "", false)
			if count, err := backend.RedactSandboxCommandPayloads(ctx, now.Add(-24*time.Hour), now, 1); err != nil || count != 1 {
				t.Fatalf("bounded redaction=%d %v", count, err)
			}
			redacted, err := backend.GetSandboxCommand(ctx, first.AccountID, first.SandboxID, first.ID)
			if err != nil || !redacted.PayloadExpired || redacted.PayloadExpiredAt == nil ||
				len(redacted.Arguments) != 0 || redacted.Environment != nil || redacted.WorkingDirectory != "" ||
				redacted.StandardOutput != "" || redacted.StandardError != "" || len(redacted.RequestDigest) != 64 {
				t.Fatalf("payload was not removed: %+v error=%v", redacted, err)
			}
			if redacted.State != SandboxCommandSucceeded || redacted.ExitCode == nil || *redacted.ExitCode != 0 || !redacted.CompletedAt.Equal(first.CreatedAt.Add(time.Second)) {
				t.Fatal("retention changed command outcome metadata")
			}
			encoded, _ := json.Marshal(redacted)
			if strings.Contains(string(encoded), "sensitive") || strings.Contains(string(encoded), "request_digest") || !strings.Contains(string(encoded), `"payload_expired":true`) {
				t.Fatalf("expiry JSON leaks payload or omits status: %s", encoded)
			}
			replay := *first
			replay.ID = uuid.NewString()
			replay.RequestDigest = "caller-supplied-forgery"
			stored, created, err := backend.CreateSandboxCommand(ctx, &replay)
			if err != nil || created || stored.ID != first.ID || !stored.SameRequest(&replay) || !stored.PayloadExpired {
				t.Fatalf("expired idempotency replay=%+v created=%v err=%v", stored, created, err)
			}
			changed := replay
			changed.Arguments = []string{"/usr/bin/false"}
			changed.RequestDigest = stored.RequestDigest
			if stored.SameRequest(&changed) {
				t.Fatal("caller commitment bypassed changed request detection")
			}
			output := "sensitive-output"
			code := int32(0)
			if _, err := backend.ApplySandboxCommandUpdate(ctx, SandboxCommandUpdate{CommandID: first.ID, SandboxID: first.SandboxID,
				Generation: first.Generation, FencingToken: first.FencingToken, State: SandboxCommandSucceeded, ExitCode: &code,
				StandardOutput: &output, StandardError: &output, UpdatedAt: now}); err == nil {
				t.Fatal("late host result rehydrated expired payload")
			}
			if count, err := backend.RedactSandboxCommandPayloads(ctx, now.Add(-24*time.Hour), now, 1000); err != nil || count != 1 {
				t.Fatalf("second redaction=%d %v", count, err)
			}
			for _, command := range []*SandboxCommand{recent, cancelling, active} {
				stored, err := backend.GetSandboxCommand(ctx, command.AccountID, command.SandboxID, command.ID)
				if err != nil || stored.PayloadExpired || len(stored.Arguments) == 0 {
					t.Fatalf("ineligible command redacted: %+v %v", stored, err)
				}
			}
			storedSecond, _ := backend.GetSandboxCommand(ctx, second.AccountID, second.SandboxID, second.ID)
			if !storedSecond.PayloadExpired {
				t.Fatal("second old terminal command was not redacted")
			}
			if _, err := backend.GetSandboxCommand(ctx, "another-account", first.SandboxID, first.ID); !errors.Is(err, ErrNotFound) {
				t.Fatal("expired result lost account isolation")
			}
			summary, err := backend.ListSandboxCommands(ctx, first.AccountID, first.SandboxID, 100)
			if err != nil {
				t.Fatal(err)
			}
			foundExpired := false
			for _, record := range summary {
				if record.ID == first.ID {
					foundExpired = record.PayloadExpired
				}
			}
			if !foundExpired {
				t.Fatal("history omitted payload expiry")
			}
		})
	}
}

func TestSandboxRequestCommitmentPreservesNilEnvironmentSemantics(t *testing.T) {
	command := &SandboxCommand{AccountID: "account", SandboxID: uuid.NewString(), IdempotencyKey: uuid.NewString(),
		Arguments: []string{"/usr/bin/true"}, TimeoutSeconds: 60, WorkingDirectory: "/workspace"}
	command.RequestDigest = sandboxCommandRequestDigest(command)
	copy := *command
	copy.Environment = map[string]string{}
	if command.SameRequest(&copy) {
		t.Fatal("empty and omitted environment became equivalent")
	}
	copy = *command
	copy.AccountID = "another-account"
	if command.SameRequest(&copy) {
		t.Fatal("commitment did not bind account")
	}
	copy = *command
	copy.SandboxID = uuid.NewString()
	if command.SameRequest(&copy) {
		t.Fatal("commitment did not bind sandbox")
	}
}

func TestSandboxLegacyPayloadGetsCommitmentBeforeRedaction(t *testing.T) {
	for name, inner := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Millisecond)
			sandbox := retentionSandbox(t, inner, now)
			command := retentionCommand(t, inner, sandbox, now.Add(-48*time.Hour), SandboxCommandSucceeded, false)
			switch backend := inner.(type) {
			case *MemoryStore:
				backend.mu.Lock()
				backend.sandboxCommands[command.ID].RequestDigest = ""
				backend.mu.Unlock()
			case *PostgresStore:
				if _, err := backend.pool.Exec(ctx, `UPDATE sandbox_commands SET request_digest = '' WHERE id = $1`, command.ID); err != nil {
					t.Fatal(err)
				}
			}
			if count, err := inner.RedactSandboxCommandPayloads(ctx, now.Add(-24*time.Hour), now, 32); err != nil || count != 1 {
				t.Fatalf("legacy redaction=%d %v", count, err)
			}
			stored, err := inner.GetSandboxCommand(ctx, command.AccountID, command.SandboxID, command.ID)
			if err != nil || !stored.PayloadExpired || !stored.SameRequest(command) {
				t.Fatalf("legacy replay lost after clearing: %+v %v", stored, err)
			}
		})
	}
}

func retentionSandbox(t *testing.T, backend SandboxStore, now time.Time) *SandboxRecord {
	t.Helper()
	ctx := context.Background()
	sandbox, prepare := sandboxFencingFixture(uuid.NewString(), uuid.NewString(), uuid.NewString(), uniqueID("retention"), uuid.NewString(), 1, now.Add(-72*time.Hour))
	sandbox.LeaseExpiresAt = now.Add(time.Hour)
	prepare.RequestedLeaseExpiresAt = sandbox.LeaseExpiresAt
	stored, _, _, err := backend.CreateSandbox(ctx, sandbox, prepare, SandboxAllocationLimits{MaximumActive: 10, MaximumPerAccount: 10, MaximumPerHost: 10})
	if err != nil {
		t.Fatal(err)
	}
	ready, _, err := backend.ApplySandboxOperationUpdate(ctx, SandboxOperationUpdate{OperationID: prepare.ID, SandboxID: stored.ID,
		Generation: stored.Generation, FencingToken: stored.FencingToken, State: SandboxOperationReady, UpdatedAt: sandbox.CreatedAt})
	if err != nil {
		t.Fatal(err)
	}
	return ready
}

func retentionCommand(t *testing.T, backend SandboxStore, sandbox *SandboxRecord, created time.Time, state string, cancellation bool) *SandboxCommand {
	t.Helper()
	ctx := context.Background()
	command := &SandboxCommand{ID: uuid.NewString(), SandboxID: sandbox.ID, AccountID: sandbox.AccountID, IdempotencyKey: uuid.NewString(),
		Generation: sandbox.Generation, FencingToken: sandbox.FencingToken, Arguments: []string{"/usr/bin/printf", "sensitive-argument"},
		Environment: map[string]string{"TEST_SECRET": "sensitive-environment"}, WorkingDirectory: "/workspace/sensitive-project", TimeoutSeconds: 60,
		State: SandboxCommandPending, CreatedAt: created, UpdatedAt: created, RequestDigest: "caller-digest-must-not-be-trusted"}
	stored, _, err := backend.CreateSandboxCommand(ctx, command)
	if err != nil {
		t.Fatal(err)
	}
	if stored.RequestDigest == command.RequestDigest {
		t.Fatal("store trusted caller-supplied request commitment")
	}
	if state != "" {
		output, exitCode := "sensitive-output", int32(0)
		if _, err := backend.ApplySandboxCommandUpdate(ctx, SandboxCommandUpdate{CommandID: command.ID, SandboxID: command.SandboxID,
			Generation: command.Generation, FencingToken: command.FencingToken, State: state, ExitCode: &exitCode,
			StandardOutput: &output, StandardError: &output, RequestCancellation: cancellation, UpdatedAt: created.Add(time.Second)}); err != nil {
			t.Fatal(err)
		}
	}
	return command
}
