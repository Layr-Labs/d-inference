package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

func TestSandboxFileAPIOverAuthenticatedHostWebSocket(t *testing.T) {
	server := newSandboxHostTestServer(t)
	sandbox, _ := seedSandboxAPIResource(t, server.store, false)
	httpServer := httptest.NewServer(server.Handler())
	defer httpServer.Close()
	connection := dialSandboxHost(t, httpServer.URL, testSandboxHostID, testSandboxHostToken)
	defer connection.Close(websocket.StatusNormalClosure, "test complete")
	registration := sandboxHostRegistrationFrame(1)
	registration.Payload.Capabilities.SupportsFiles = true
	writeSandboxHostFrame(t, connection, registration)
	writeSandboxHostFrame(t, connection, sandboxHostHeartbeatFrame(2))
	waitForSandboxHost(t, server, func(snapshot sandboxhost.HostSnapshot) bool { return snapshot.Heartbeat != nil })
	data := []byte("file contents stay out of command records\n")
	digestBytes := sha256.Sum256(data)
	digest := hex.EncodeToString(digestBytes[:])
	transferID := uuid.NewString()
	version := strings.Repeat("a", 64)
	size := uint64(len(data))
	base := "/v1/sandboxes/" + sandbox.ID + "/files"
	type step struct {
		method, path, contentType string
		body                      []byte
		operation, state          string
		offset                    uint64
	}
	steps := []step{
		{http.MethodPost, base + "/directories", "application/json", []byte(`{"path":"src"}`), protocol.SandboxFileMkdir, "", 0},
		{http.MethodPost, base + "/uploads", "application/json", []byte(fmt.Sprintf(`{"transfer_id":%q,"path":"src/test.txt","size":%d,"sha256":%q}`, transferID, size, digest)), protocol.SandboxFileUploadBegin, "uploading", 0},
		{http.MethodPut, base + "/uploads/" + transferID + "/chunks?offset=0", "application/octet-stream", data, protocol.SandboxFileUploadChunk, "uploading", size},
		{http.MethodGet, base + "/uploads/" + transferID, "", nil, protocol.SandboxFileUploadStatus, "uploading", size},
		{http.MethodPost, base + "/uploads/" + transferID + "/commit", "", nil, protocol.SandboxFileUploadCommit, "committed", size},
		{http.MethodGet, base + "?path=src/test.txt&offset=0&length=512", "", nil, protocol.SandboxFileDownload, "", 0},
		{http.MethodGet, base + "?path=src/test.txt&offset=5&length=512&version=" + version, "", nil, protocol.SandboxFileDownload, "", 5},
		{http.MethodDelete, base + "/uploads/" + transferID, "", nil, protocol.SandboxFileUploadAbort, "aborted", 0},
	}
	for index, step := range steps {
		t.Run(step.operation, func(t *testing.T) {
			type outcome struct {
				status int
				body   []byte
				header http.Header
				err    error
			}
			outcomes := make(chan outcome, 1)
			go func() {
				request, err := http.NewRequest(step.method, httpServer.URL+step.path, bytes.NewReader(step.body))
				if err != nil {
					outcomes <- outcome{err: err}
					return
				}
				request.Header.Set("Authorization", "Bearer test-key")
				if step.contentType != "" {
					request.Header.Set("Content-Type", step.contentType)
				}
				response, err := http.DefaultClient.Do(request)
				if err != nil {
					outcomes <- outcome{err: err}
					return
				}
				defer response.Body.Close()
				body, err := io.ReadAll(response.Body)
				outcomes <- outcome{response.StatusCode, body, response.Header, err}
			}()
			message := readSandboxCoordinatorMessage(t, connection)
			payload, ok := message.Payload.(*protocol.SandboxFileOperationPayload)
			if !ok || payload.Operation != step.operation || payload.Scope.SandboxID != sandbox.ID {
				t.Fatalf("incorrect file request: %#v", message.Payload)
			}
			result := protocol.SandboxFileResultPayload{RequestID: payload.RequestID, Scope: payload.Scope, Operation: payload.Operation, Success: true}
			if step.state != "" {
				result.TransferID = &transferID
				result.State = &step.state
				if step.operation != protocol.SandboxFileUploadAbort {
					result.Offset = &step.offset
					result.Size = &size
					result.SHA256 = &digest
				}
			}
			if step.operation == protocol.SandboxFileUploadChunk {
				decoded, err := protocol.DecodeSandboxFileData(*payload.Data)
				if err != nil || !bytes.Equal(decoded, data) {
					t.Fatal("raw upload bytes changed in transit")
				}
			}
			if step.operation == protocol.SandboxFileDownload {
				chunk := data[*payload.Offset:]
				chunkHash := sha256.Sum256(chunk)
				chunkDigest := hex.EncodeToString(chunkHash[:])
				encoded := base64.StdEncoding.EncodeToString(chunk)
				result.Data = &encoded
				result.Offset = payload.Offset
				result.Size = &size
				result.SHA256 = &chunkDigest
				result.Version = &version
				if *payload.Offset > 0 && (payload.Version == nil || *payload.Version != version) {
					t.Fatal("download version was lost in transit")
				}
			}
			if step.operation == protocol.SandboxFileUploadAbort {
				code := "upload_already_committed"
				result.Success = false
				result.ErrorCode = &code
				result.State = nil
			}
			writeSandboxHostFrame(t, connection, protocol.SandboxEnvelope[protocol.SandboxFileResultPayload]{
				Type: protocol.SandboxTypeFileResult, ProtocolVersion: protocol.SandboxProtocolVersion,
				HostID: testSandboxHostID, ConnectionEpoch: testSandboxHostEpoch, Sequence: uint64(index + 3), Payload: result,
			})
			select {
			case response := <-outcomes:
				expectedStatus := http.StatusOK
				if step.operation == protocol.SandboxFileUploadAbort {
					expectedStatus = http.StatusConflict
				}
				if response.err != nil || response.status != expectedStatus {
					t.Fatalf("response=%+v", response)
				}
				if step.operation == protocol.SandboxFileUploadAbort && !strings.Contains(string(response.body), "upload_already_committed") {
					t.Fatal("committed upload was falsely reported aborted")
				}
				if response.header.Get("Cache-Control") != "no-store" {
					t.Fatal("file result is cacheable")
				}
				if step.operation == protocol.SandboxFileDownload {
					chunk := data[step.offset:]
					chunkHash := sha256.Sum256(chunk)
					if !bytes.Equal(response.body, chunk) || response.header.Get("X-Sandbox-Chunk-SHA256") != hex.EncodeToString(chunkHash[:]) || response.header.Get("X-Sandbox-File-Size") != fmt.Sprint(size) || response.header.Get("X-Sandbox-File-Version") != version {
						t.Fatal("download payload or integrity headers changed")
					}
				} else if strings.Contains(string(response.body), `"scope"`) {
					t.Fatal("internal scope leaked in consumer metadata")
				}
			case <-time.After(3 * time.Second):
				t.Fatal("HTTP file operation did not receive host result")
			}
		})
	}
	commands, err := server.store.ListSandboxCommands(context.Background(), sandbox.AccountID, sandbox.ID, 100)
	if err != nil || len(commands) != 0 {
		t.Fatalf("file transfer used durable command plane: %+v %v", commands, err)
	}
}

func TestSandboxFileAPIRejectsUnsafeInputsBeforeRelay(t *testing.T) {
	server := newSandboxHostTestServer(t)
	sandbox, _ := seedSandboxAPIResource(t, server.store, false)
	base := "/v1/sandboxes/" + sandbox.ID + "/files"
	transferID := uuid.NewString()
	for _, test := range []struct {
		name, method, path, contentType string
		body                            []byte
		status                          int
	}{
		{"parent path", http.MethodPost, base + "/directories", "application/json", []byte(`{"path":"../outside"}`), 400},
		{"command injection", http.MethodPost, base + "/directories", "application/json", []byte(`{"path":"src","command":{"executable":"/bin/sh"}}`), 400},
		{"credential injection", http.MethodPost, base + "/uploads", "application/json", []byte(`{"credential":"secret"}`), 400},
		{"oversized chunk", http.MethodPut, base + "/uploads/" + transferID + "/chunks?offset=0", "application/octet-stream", make([]byte, protocol.SandboxMaximumFileChunkBytes+1), 413},
		{"invalid chunk content", http.MethodPut, base + "/uploads/" + transferID + "/chunks?offset=0", "application/json", []byte(`{}`), 415},
		{"ambiguous offset", http.MethodPut, base + "/uploads/" + transferID + "/chunks?offset=0&offset=1", "application/octet-stream", []byte("a"), 400},
		{"oversized download", http.MethodGet, base + "?path=file&length=524289", "", nil, 400},
		{"absolute download", http.MethodGet, base + "?path=/etc/passwd", "", nil, 400},
		{"later chunk without version", http.MethodGet, base + "?path=file&offset=1", "", nil, 400},
	} {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(test.method, test.path, bytes.NewReader(test.body))
			request.Header.Set("Authorization", "Bearer test-key")
			request.Header.Set("Content-Type", test.contentType)
			response := httptest.NewRecorder()
			server.Handler().ServeHTTP(response, request)
			if response.Code != test.status {
				t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
	otherKey, err := server.store.CreateKeyForAccount("other")
	if err != nil {
		t.Fatal(err)
	}
	response := sandboxLocalAPIRequest(server, http.MethodGet, base+"?path=file", otherKey)
	if response.Code != http.StatusNotFound {
		t.Fatalf("other-account download status=%d", response.Code)
	}
}

func TestSandboxFileAPIAdmissionAndCleanupSplit(t *testing.T) {
	server := newSandboxHostTestServer(t, func(config *ServerConfig) { config.SandboxService.AdmissionEnabled = false })
	sandbox, _ := seedSandboxAPIResource(t, server.store, false)
	base := "/v1/sandboxes/" + sandbox.ID + "/files"
	for _, path := range []string{base + "/directories", base + "/uploads", base + "/uploads/" + uuid.NewString() + "/commit"} {
		response := sandboxLocalAPIRequest(server, http.MethodPost, path, "test-key")
		if response.Code != http.StatusServiceUnavailable || !strings.Contains(response.Body.String(), "sandbox_draining") {
			t.Fatalf("new upload admitted during drain: %s", response.Body.String())
		}
	}
	for _, method := range []string{http.MethodGet, http.MethodDelete} {
		response := sandboxLocalAPIRequest(server, method, base+"/uploads/"+uuid.NewString(), "test-key")
		var payload map[string]any
		if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(response.Body.String(), "sandbox_draining") {
			t.Fatal("drain gate blocked transfer inspection/abort")
		}
	}
}
