package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const fixtureSandboxID = "10000000-0000-0000-0000-000000000001"
const fixtureOperationID = "20000000-0000-0000-0000-000000000002"
const fixtureCommandID = "30000000-0000-0000-0000-000000000003"
const fixtureAPIKey = "offline-fixture-api-key-no-production-access"

// This offline coordinator fixture exercises the real CLI HTTP client and file
// publication. The companion API tests separately exercise authenticated host
// WebSockets; this fixture does not claim physical VM execution.
type workflowCoordinator struct {
	mu                     sync.Mutex
	server                 *httptest.Server
	state                  string
	transfer               transferRecord
	file                   []byte
	arguments              []string
	commandKey             string
	chunkCalls             map[uint64]int
	downloadCalls          int
	loseFirstChunkResponse bool
	mixedVersion           bool
	corruptChunk           bool
}

func newWorkflowCoordinator(t *testing.T) *workflowCoordinator {
	t.Helper()
	fixture := &workflowCoordinator{state: "ready", chunkCalls: make(map[uint64]int)}
	fixture.server = httptest.NewServer(http.HandlerFunc(fixture.serveHTTP))
	t.Cleanup(fixture.server.Close)
	return fixture
}

func (f *workflowCoordinator) serveHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.Header.Get("Authorization") != "Bearer "+fixtureAPIKey {
		http.Error(w, "unauthorized", 401)
		return
	}
	jsonResult := func(value any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(value)
	}
	sandbox := sandboxRecord{ID: fixtureSandboxID, State: f.state, BaseImageID: "macos-tahoe-v1", CPUCount: 4, MemoryBytes: 8 << 30, WorkspaceBytes: 25 << 30, LeaseExpiresAt: time.Now().Add(time.Hour)}
	operation := operationResponse{Sandbox: &sandbox, Operation: &operationRecord{ID: fixtureOperationID, State: "ready"}}
	base := "/v1/sandboxes/" + fixtureSandboxID
	switch {
	case r.URL.Path == "/v1/sandboxes" && r.Method == http.MethodPost:
		if !protocol.ValidSandboxUUID(r.Header.Get("Idempotency-Key")) {
			http.Error(w, "key required", 400)
			return
		}
		jsonResult(operation)
	case r.URL.Path == "/v1/sandboxes" && r.Method == http.MethodGet:
		jsonResult(struct {
			Data []sandboxRecord `json:"data"`
		}{[]sandboxRecord{sandbox}})
	case r.URL.Path == "/v1/sandbox-operations/"+fixtureOperationID:
		jsonResult(operation)
	case r.URL.Path == base && r.Method == http.MethodGet:
		jsonResult(sandbox)
	case r.URL.Path == base && r.Method == http.MethodDelete:
		f.state = "deleted"
		jsonResult(operation)
	case r.URL.Path == base+"/stop":
		f.state = "stopped"
		jsonResult(operation)
	case r.URL.Path == base+"/renew":
		jsonResult(operation)
	case r.URL.Path == base+"/start":
		f.state = "ready"
		jsonResult(operation)
	case r.URL.Path == base+"/commands" && r.Method == http.MethodPost:
		var input struct {
			Arguments        []string `json:"arguments"`
			WorkingDirectory string   `json:"working_directory"`
		}
		if json.NewDecoder(r.Body).Decode(&input) != nil || input.WorkingDirectory != "/workspace" {
			http.Error(w, "invalid command", 400)
			return
		}
		f.arguments = input.Arguments
		f.commandKey = r.Header.Get("Idempotency-Key")
		code := int32(0)
		jsonResult(commandResponse{&commandRecord{ID: fixtureCommandID, SandboxID: fixtureSandboxID, State: "succeeded", ExitCode: &code, StandardOutput: "fixture output\n"}})
	case r.URL.Path == base+"/commands" && r.Method == http.MethodGet:
		jsonResult(struct {
			Data []commandRecord `json:"data"`
		}{[]commandRecord{{ID: fixtureCommandID, SandboxID: fixtureSandboxID, State: "succeeded"}}})
	case r.URL.Path == base+"/files/directories":
		jsonResult(map[string]string{"request_id": fixtureOperationID})
	case r.URL.Path == base+"/files/uploads" && r.Method == http.MethodPost:
		var input struct {
			TransferID, Path, SHA256 string
			Size                     uint64
		}
		var raw map[string]json.RawMessage
		if json.NewDecoder(r.Body).Decode(&raw) != nil {
			http.Error(w, "invalid upload", 400)
			return
		}
		_ = json.Unmarshal(raw["transfer_id"], &input.TransferID)
		_ = json.Unmarshal(raw["path"], &input.Path)
		_ = json.Unmarshal(raw["sha256"], &input.SHA256)
		_ = json.Unmarshal(raw["size"], &input.Size)
		if f.transfer.TransferID == "" {
			f.transfer = transferRecord{TransferID: input.TransferID, State: "uploading", Size: input.Size, SHA256: input.SHA256}
		}
		if f.transfer.TransferID != input.TransferID || f.transfer.Size != input.Size || f.transfer.SHA256 != input.SHA256 {
			http.Error(w, "conflict", 409)
			return
		}
		jsonResult(f.transfer)
	case r.URL.Path == base+"/files":
		f.download(w, r)
	case strings.HasPrefix(r.URL.Path, base+"/files/uploads/"):
		f.upload(w, r, jsonResult)
	default:
		http.Error(w, "unknown fixture route", 404)
	}
}

func (f *workflowCoordinator) upload(w http.ResponseWriter, r *http.Request, jsonResult func(any)) {
	path := "/v1/sandboxes/" + fixtureSandboxID + "/files/uploads/" + f.transfer.TransferID
	switch {
	case r.URL.Path == path && r.Method == http.MethodGet:
		jsonResult(f.transfer)
	case r.URL.Path == path && r.Method == http.MethodDelete:
		if f.transfer.State == "committed" {
			w.WriteHeader(http.StatusConflict)
			jsonResult(map[string]any{"error": map[string]string{"code": "upload_already_committed", "type": "sandbox_file_error"}})
			return
		}
		f.transfer.State = "aborted"
		jsonResult(f.transfer)
	case r.URL.Path == path+"/chunks" && r.Method == http.MethodPut:
		offset, err := strconv.ParseUint(r.URL.Query().Get("offset"), 10, 64)
		if err != nil || offset != uint64(len(f.file)) || r.Header.Get("Content-Type") != "application/octet-stream" {
			http.Error(w, "offset conflict", 409)
			return
		}
		data, err := io.ReadAll(io.LimitReader(r.Body, protocol.SandboxMaximumFileChunkBytes+1))
		if err != nil || len(data) > protocol.SandboxMaximumFileChunkBytes {
			http.Error(w, "bad chunk", 400)
			return
		}
		f.chunkCalls[offset]++
		f.file = append(f.file, data...)
		f.transfer.Offset = uint64(len(f.file))
		if f.loseFirstChunkResponse && offset == 0 {
			f.loseFirstChunkResponse = false
			http.Error(w, "simulated lost reply", 504)
			return
		}
		jsonResult(f.transfer)
	case r.URL.Path == path+"/commit" && r.Method == http.MethodPost:
		hash := sha256.Sum256(f.file)
		if uint64(len(f.file)) != f.transfer.Size || hex.EncodeToString(hash[:]) != f.transfer.SHA256 {
			http.Error(w, "checksum mismatch", 409)
			return
		}
		f.transfer.State = "committed"
		jsonResult(f.transfer)
	default:
		http.Error(w, "unknown transfer", 404)
	}
}

func (f *workflowCoordinator) download(w http.ResponseWriter, r *http.Request) {
	f.downloadCalls++
	offset, err := strconv.ParseUint(r.URL.Query().Get("offset"), 10, 64)
	if err != nil || offset > uint64(len(f.file)) {
		http.Error(w, "invalid offset", 400)
		return
	}
	version := strings.Repeat("a", 64)
	if offset > 0 && r.URL.Query().Get("version") != version {
		http.Error(w, "version required", 409)
		return
	}
	if f.mixedVersion && offset > 0 {
		version = strings.Repeat("b", 64)
	}
	end := min(offset+protocol.SandboxMaximumFileChunkBytes, uint64(len(f.file)))
	chunk := f.file[offset:end]
	hash := sha256.Sum256(chunk)
	digest := hex.EncodeToString(hash[:])
	if f.corruptChunk {
		digest = strings.Repeat("0", 64)
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Sandbox-File-Size", fmt.Sprint(len(f.file)))
	w.Header().Set("X-Sandbox-File-Offset", fmt.Sprint(offset))
	w.Header().Set("X-Sandbox-Chunk-SHA256", digest)
	w.Header().Set("X-Sandbox-File-Version", version)
	_, _ = w.Write(chunk)
}
