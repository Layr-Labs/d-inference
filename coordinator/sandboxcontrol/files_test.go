package sandboxcontrol

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func TestSandboxFileRelayScopeAndReconnect(t *testing.T) {
	for _, scenario := range []string{"reply", "disconnect", "cancel", "wrong-scope", "wrong-session", "renewed-fence"} {
		t.Run(scenario, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			now := time.Now().UTC()
			backend := store.NewMemory(store.Config{})
			sandbox := createReadyTestSandbox(t, backend, now)
			controller := testSandboxController(backend, &now)
			transport := &fileTestTransport{requests: make(chan *protocol.SandboxFileOperationPayload, 1)}
			session := registerFileTestHost(t, controller.hosts, sandbox, transport)
			result := make(chan error, 1)
			path := "src"
			go func() {
				_, err := controller.FileOperation(ctx, sandbox.AccountID, sandbox.ID, FileRequest{Operation: protocol.SandboxFileMkdir, Path: &path})
				result <- err
			}()
			var request *protocol.SandboxFileOperationPayload
			select {
			case request = <-transport.requests:
			case <-time.After(2 * time.Second):
				t.Fatal("file request was not relayed")
			}
			response := &protocol.SandboxFileResultPayload{RequestID: request.RequestID, Scope: request.Scope, Operation: request.Operation, Success: true}
			switch scenario {
			case "reply":
				if err := controller.handleFileResult(session, response); err != nil {
					t.Fatal(err)
				}
			case "disconnect":
				controller.hosts.Disconnect(session)
			case "cancel":
				cancel()
			case "wrong-scope":
				response.Scope.FencingToken++
				if !IsStaleHostResult(controller.handleFileResult(session, response)) {
					t.Fatal("wrong fence accepted")
				}
				cancel()
			case "wrong-session":
				replacement := registerFileTestHost(t, controller.hosts, sandbox, transport)
				if !IsStaleHostResult(controller.handleFileResult(replacement, response)) {
					t.Fatal("replacement session completed old relay")
				}
			case "renewed-fence":
				now = now.Add(45 * time.Minute)
				operation, err := controller.Renew(ctx, sandbox.AccountID, sandbox.ID, uuid.NewString())
				if err != nil {
					t.Fatal(err)
				}
				if _, _, err := backend.ApplySandboxOperationUpdate(ctx, store.SandboxOperationUpdate{
					OperationID: operation.ID, SandboxID: sandbox.ID, Generation: sandbox.Generation,
					FencingToken: operation.RequestedFencingToken, State: store.SandboxOperationReady,
					LeaseExpiresAt: &operation.RequestedLeaseExpiresAt, UpdatedAt: now,
				}); err != nil {
					t.Fatal(err)
				}
				if err := controller.handleFileResult(session, response); err != nil {
					t.Fatal(err)
				}
			}
			select {
			case err := <-result:
				if scenario == "reply" && err != nil || scenario != "reply" && err == nil {
					t.Fatalf("relay outcome: %v", err)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("relay did not exit when authority ended")
			}
			controller.fileMu.Lock()
			count := len(controller.pendingFileRequests)
			controller.fileMu.Unlock()
			if count != 0 {
				t.Fatal("completed relay retained pending memory")
			}
			if !IsStaleHostResult(controller.handleFileResult(session, response)) {
				t.Fatal("late result accepted")
			}
		})
	}
}

func TestSandboxFileRelayAccountLimitsAndTimeout(t *testing.T) {
	now := time.Now().UTC()
	backend := store.NewMemory(store.Config{})
	sandbox := createReadyTestSandbox(t, backend, now)
	controller := testSandboxController(backend, &now)
	path := "src"
	if _, err := controller.FileOperation(context.Background(), "other", sandbox.ID, FileRequest{Operation: protocol.SandboxFileMkdir, Path: &path}); !errors.Is(err, store.ErrNotFound) {
		t.Fatal("other account accessed file relay")
	}
	transport := &fileTestTransport{requests: make(chan *protocol.SandboxFileOperationPayload, 1)}
	registerFileTestHost(t, controller.hosts, sandbox, transport)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, err := controller.FileOperation(ctx, sandbox.AccountID, sandbox.ID, FileRequest{Operation: protocol.SandboxFileMkdir, Path: &path}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("timeout: %v", err)
	}
	for range maximumPendingFilesPerAccount {
		if err := controller.addFileRequest(uuid.NewString(), &pendingSandboxFileRequest{accountID: sandbox.AccountID}); err != nil {
			t.Fatal(err)
		}
	}
	if !errors.Is(controller.addFileRequest(uuid.NewString(), &pendingSandboxFileRequest{accountID: sandbox.AccountID}), ErrFileRelayBusy) {
		t.Fatal("account pending budget exceeded")
	}
}

func TestSandboxFileRelayRejectsMixedDownloadRevision(t *testing.T) {
	now := time.Now().UTC()
	backend := store.NewMemory(store.Config{})
	sandbox := createReadyTestSandbox(t, backend, now)
	controller := testSandboxController(backend, &now)
	transport := &fileTestTransport{requests: make(chan *protocol.SandboxFileOperationPayload, 1)}
	session := registerFileTestHost(t, controller.hosts, sandbox, transport)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	path, version := "artifact.bin", strings.Repeat("a", 64)
	offset, length := uint64(1), uint64(2)
	completed := make(chan error, 1)
	go func() {
		_, err := controller.FileOperation(ctx, sandbox.AccountID, sandbox.ID,
			FileRequest{Operation: protocol.SandboxFileDownload, Path: &path, Offset: &offset, Size: &length, Version: &version})
		completed <- err
	}()
	var request *protocol.SandboxFileOperationPayload
	select {
	case request = <-transport.requests:
	case <-time.After(time.Second):
		t.Fatal("download not dispatched")
	}
	bytes := []byte("bc")
	encoded := base64.StdEncoding.EncodeToString(bytes)
	hash := sha256.Sum256(bytes)
	digest := hex.EncodeToString(hash[:])
	changedVersion, size := strings.Repeat("b", 64), uint64(3)
	response := &protocol.SandboxFileResultPayload{RequestID: request.RequestID, Scope: request.Scope, Operation: protocol.SandboxFileDownload,
		Success: true, Data: &encoded, Offset: &offset, Size: &size, SHA256: &digest, Version: &changedVersion}
	if !IsStaleHostResult(controller.handleFileResult(session, response)) {
		t.Fatal("mixed download revision accepted")
	}
	cancel()
	select {
	case err := <-completed:
		if err == nil {
			t.Fatal("unverified download returned to consumer")
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled download remained pending")
	}
}

type fileTestTransport struct {
	requests chan *protocol.SandboxFileOperationPayload
}

func (t *fileTestTransport) Write(ctx context.Context, encoded []byte) error {
	message, err := protocol.DecodeSandboxCoordinatorMessage(encoded)
	if err != nil {
		return err
	}
	payload, ok := message.Payload.(*protocol.SandboxFileOperationPayload)
	if !ok {
		return errors.New("unexpected relay payload")
	}
	select {
	case t.requests <- payload:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (t *fileTestTransport) Close(string) error { return nil }

func registerFileTestHost(t *testing.T, hosts *sandboxhost.Registry, sandbox *store.SandboxRecord, transport sandboxhost.Transport) *sandboxhost.Session {
	t.Helper()
	session, err := hosts.Register(protocol.SandboxMessageHeader{HostID: sandbox.HostID, ConnectionEpoch: uuid.NewString(), Sequence: 1},
		&protocol.SandboxHostRegisterPayload{Capabilities: protocol.SandboxHostCapabilities{SupportsFiles: true}}, transport)
	if err != nil {
		t.Fatal(err)
	}
	return session
}
