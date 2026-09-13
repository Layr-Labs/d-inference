package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func TestSandboxCleanupAndRetrievalRemainAvailableDuringDrain(t *testing.T) {
	for _, admissionEnabled := range []bool{false, true} {
		for _, operation := range []string{"stop", "delete", "cancel"} {
			t.Run(operation+"/admission="+map[bool]string{false: "paused", true: "unenrolled"}[admissionEnabled], func(t *testing.T) {
				server := newSandboxHostTestServer(t, func(config *ServerConfig) {
					config.SandboxService = SandboxServiceConfig{
						Enabled: true, AdmissionEnabled: admissionEnabled, AllowedAccountIDs: []string{"other-account"},
					}
				})
				sandbox, command := seedSandboxAPIResource(t, server.store, operation == "cancel")
				server.SetDraining(true)
				base := "/v1/sandboxes/" + sandbox.ID
				for _, path := range []string{base, base + "/commands"} {
					response := sandboxLocalAPIRequest(server, http.MethodGet, path, "test-key")
					if response.Code != http.StatusOK {
						t.Fatalf("read during drain: status=%d body=%s", response.Code, response.Body.String())
					}
				}
				method, path := http.MethodPost, base+"/stop"
				if operation == "delete" {
					method, path = http.MethodDelete, base
				} else if operation == "cancel" {
					path = base + "/commands/" + command.ID + "/cancel"
				}
				response := sandboxLocalAPIRequest(server, method, path, "test-key")
				if response.Code != http.StatusAccepted {
					t.Fatalf("cleanup during drain: status=%d body=%s", response.Code, response.Body.String())
				}
				if operation == "cancel" {
					stored, err := server.store.GetSandboxCommand(context.Background(), sandbox.AccountID, sandbox.ID, command.ID)
					if err != nil || !stored.CancellationPending || stored.State != store.SandboxCommandCancelled {
						t.Fatalf("cancellation not durable: %+v %v", stored, err)
					}
				}
				otherKey, err := server.store.CreateKeyForAccount("other-account")
				if err != nil {
					t.Fatal(err)
				}
				for _, otherPath := range []string{base, base + "/commands", path} {
					otherMethod := http.MethodGet
					if otherPath == path {
						otherMethod = method
					}
					response := sandboxLocalAPIRequest(server, otherMethod, otherPath, otherKey)
					if response.Code != http.StatusNotFound {
						t.Fatalf("cross-account cleanup/read status=%d body=%s", response.Code, response.Body.String())
					}
				}
			})
		}
	}
}

func sandboxLocalAPIRequest(server *Server, method, path, token string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, path, nil)
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Idempotency-Key", uuid.NewString())
	response := httptest.NewRecorder()
	server.Handler().ServeHTTP(response, request)
	return response
}

func seedSandboxAPIResource(t *testing.T, backend store.SandboxStore, includeCommand bool) (*store.SandboxRecord, *store.SandboxCommand) {
	t.Helper()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	sandbox := &store.SandboxRecord{
		ID: uuid.NewString(), AccountID: store.LegacyAccountID("test-key"), IdempotencyKey: uuid.NewString(),
		HostID: testSandboxHostID, Generation: 1, FencingToken: 1, BaseImageID: "macos-tahoe-v1",
		CPUCount: 4, MemoryBytes: 8 << 30, WorkspaceBytes: 25 << 30, CommandTimeoutSeconds: 900,
		State: store.SandboxStatePreparing, LeaseExpiresAt: now.Add(time.Hour), CreatedAt: now, UpdatedAt: now,
	}
	prepare := &store.SandboxOperation{
		ID: uuid.NewString(), SandboxID: sandbox.ID, AccountID: sandbox.AccountID, IdempotencyKey: sandbox.IdempotencyKey,
		Kind: store.SandboxOperationKindPrepare, State: store.SandboxOperationPending, Generation: 1, FencingToken: 1,
		RequestedLeaseExpiresAt: sandbox.LeaseExpiresAt, CreatedAt: now, UpdatedAt: now,
	}
	if _, _, _, err := backend.CreateSandbox(ctx, sandbox, prepare, store.SandboxAllocationLimits{
		MaximumActive: 2, MaximumPerAccount: 2, MaximumPerHost: 2,
	}); err != nil {
		t.Fatal(err)
	}
	ready, _, err := backend.ApplySandboxOperationUpdate(ctx, store.SandboxOperationUpdate{
		OperationID: prepare.ID, SandboxID: sandbox.ID, Generation: 1, FencingToken: 1,
		State: store.SandboxOperationReady, UpdatedAt: now,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !includeCommand {
		return ready, nil
	}
	command := &store.SandboxCommand{
		ID: uuid.NewString(), SandboxID: sandbox.ID, AccountID: sandbox.AccountID, IdempotencyKey: uuid.NewString(),
		Generation: 1, FencingToken: 1, Arguments: []string{"/usr/bin/sleep", "60"}, TimeoutSeconds: 60,
		State: store.SandboxCommandPending, CreatedAt: now, UpdatedAt: now,
	}
	if _, _, err := backend.CreateSandboxCommand(ctx, command); err != nil {
		t.Fatal(err)
	}
	return ready, command
}
