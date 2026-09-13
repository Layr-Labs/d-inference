package protocol

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"

	"github.com/google/uuid"
)

func TestSandboxFileProtocolRejectsUnsafePathsAndControlFields(t *testing.T) {
	id, path, digest, size := uuid.NewString(), "src/main.swift", strings.Repeat("a", 64), uint64(3)
	payload := SandboxFileOperationPayload{RequestID: uuid.NewString(), Scope: fileTestScope(),
		Operation: SandboxFileUploadBegin, TransferID: &id, Path: &path, Size: &size, SHA256: &digest}
	encoded := fileTestEnvelope(t, SandboxTypeFileOperation, payload)
	if _, err := DecodeSandboxCoordinatorMessage(encoded); err != nil {
		t.Fatal(err)
	}
	for _, unsafe := range []string{"", "/etc/passwd", "../escape", "src/../escape", "src//main", "src/./main", "src/", "nul\x00name", strings.Repeat("a", 256)} {
		candidate := payload
		candidate.Path = &unsafe
		if ValidateSandboxFileOperation(&candidate) == nil {
			t.Fatalf("unsafe path accepted: %q", unsafe)
		}
	}
	for _, field := range []string{`"credential":"secret"`, `"command":{"arguments":["/bin/sh"]}`, `"scope_override":{}`, `"executable":"/bin/sh"`} {
		injected := strings.Replace(string(encoded), `"operation":"upload_begin"`, `"operation":"upload_begin",`+field, 1)
		if _, err := DecodeSandboxCoordinatorMessage([]byte(injected)); err == nil {
			t.Fatalf("control field accepted: %s", field)
		}
	}
	for _, operation := range []string{"execute", "serve", "configure", "tenant-cleanup"} {
		candidate := payload
		candidate.Operation = operation
		if ValidateSandboxFileOperation(&candidate) == nil {
			t.Fatalf("arbitrary operation accepted: %q", operation)
		}
	}
	copy := payload
	offset := uint64(0)
	copy.Offset = &offset
	if ValidateSandboxFileOperation(&copy) == nil {
		t.Fatal("unexpected begin offset accepted")
	}
}

func TestSandboxFileProtocolBoundsBytesAndChecksDownloadDigest(t *testing.T) {
	id, offset := uuid.NewString(), uint64(0)
	data := base64.StdEncoding.EncodeToString(make([]byte, SandboxMaximumFileChunkBytes))
	payload := SandboxFileOperationPayload{RequestID: uuid.NewString(), Scope: fileTestScope(),
		Operation: SandboxFileUploadChunk, TransferID: &id, Offset: &offset, Data: &data}
	if ValidateSandboxFileOperation(&payload) != nil {
		t.Fatal("maximum chunk rejected")
	}
	for _, malformed := range []string{data + "A", data + "\n", "!!!!", "", base64.StdEncoding.EncodeToString(make([]byte, SandboxMaximumFileChunkBytes+1))} {
		candidate := payload
		candidate.Data = &malformed
		if ValidateSandboxFileOperation(&candidate) == nil {
			t.Fatal("malformed or excessive chunk accepted")
		}
	}
	bytes := []byte("downloaded bytes")
	encoded := base64.StdEncoding.EncodeToString(bytes)
	hash := sha256.Sum256(bytes)
	digest := hex.EncodeToString(hash[:])
	size := uint64(len(bytes))
	result := SandboxFileResultPayload{RequestID: uuid.NewString(), Scope: fileTestScope(),
		Operation: SandboxFileDownload, Success: true, Data: &encoded, Offset: &offset, Size: &size, SHA256: &digest, Version: &digest}
	if _, err := DecodeSandboxHostMessage(fileTestEnvelope(t, SandboxTypeFileResult, result)); err != nil {
		t.Fatal(err)
	}
	wrong := strings.Repeat("0", 64)
	result.SHA256 = &wrong
	if ValidateSandboxFileResult(&result) == nil {
		t.Fatal("corrupted download digest accepted")
	}
}

func TestSandboxFileDownloadRequiresVersionForLaterChunks(t *testing.T) {
	path, offset, size := "artifact.bin", uint64(0), uint64(512)
	version := strings.Repeat("a", 64)
	request := SandboxFileOperationPayload{RequestID: uuid.NewString(), Scope: fileTestScope(),
		Operation: SandboxFileDownload, Path: &path, Offset: &offset, Size: &size}
	if err := ValidateSandboxFileOperation(&request); err != nil {
		t.Fatal(err)
	}
	offset = 512
	if ValidateSandboxFileOperation(&request) == nil {
		t.Fatal("later chunk did not require a file version")
	}
	request.Version = &version
	if _, err := DecodeSandboxCoordinatorMessage(fileTestEnvelope(t, SandboxTypeFileOperation, request)); err != nil {
		t.Fatal(err)
	}
	bad := "not-a-version"
	request.Version = &bad
	if ValidateSandboxFileOperation(&request) == nil {
		t.Fatal("invalid file version accepted")
	}
	request = SandboxFileOperationPayload{RequestID: uuid.NewString(), Scope: fileTestScope(), Operation: SandboxFileMkdir, Path: &path, Version: &version}
	if ValidateSandboxFileOperation(&request) == nil {
		t.Fatal("version field accepted on mkdir")
	}
}

func TestSandboxCommandWorkspaceAndEnvironmentBoundary(t *testing.T) {
	cwd := "/workspace/src"
	command := &SandboxCommandPayload{CommandID: uuid.NewString(), IdempotencyKey: uuid.NewString(), Scope: fileTestScope(),
		Arguments: []string{"/usr/bin/true"}, WorkingDirectory: &cwd, TimeoutSeconds: 30}
	if ValidateSandboxCommand(command) != nil {
		t.Fatal("workspace command rejected")
	}
	for _, path := range []string{"/Users/lume", "/workspace/..", "/workspace//src", "/workspace/", "relative", "/workspace-other"} {
		copy := *command
		copy.WorkingDirectory = &path
		if ValidateSandboxCommand(&copy) == nil {
			t.Fatalf("unsafe working directory accepted: %s", path)
		}
	}
	for _, key := range []string{"HOME", "PATH", "TMPDIR", "SHELL", "ENV", "BASH_ENV", "ZDOTDIR", "DYLD_INSERT_LIBRARIES", "DARKBLOOM_TOKEN"} {
		copy := *command
		copy.Environment = map[string]string{key: "tenant"}
		if ValidateSandboxCommand(&copy) == nil {
			t.Fatalf("reserved environment accepted: %s", key)
		}
	}
}

func fileTestScope() SandboxScope {
	return SandboxScope{SandboxID: "10000000-0000-0000-0000-000000000001", Generation: 1, FencingToken: 10}
}

func fileTestEnvelope(t *testing.T, kind string, payload any) []byte {
	t.Helper()
	encoded, err := json.Marshal(SandboxEnvelope[any]{Type: kind, ProtocolVersion: SandboxProtocolVersion,
		HostID: uuid.NewString(), ConnectionEpoch: uuid.NewString(), Sequence: 1, Payload: payload})
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}
