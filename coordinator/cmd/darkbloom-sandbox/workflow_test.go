package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/google/uuid"
)

func TestOfflineConsumerWorkflowResumesUploadAndPinsDownload(t *testing.T) {
	data, err := os.ReadFile("testdata/workflow.json")
	if err != nil {
		t.Fatal(err)
	}
	var workflow struct {
		Image   string   `json:"image"`
		Command []string `json:"command"`
		File    struct {
			Path, Text string
			Repeat     int
		} `json:"file"`
	}
	if err := json.Unmarshal(data, &workflow); err != nil {
		t.Fatal(err)
	}
	fixture := newWorkflowCoordinator(t)
	fixture.loseFirstChunkResponse = true
	directory := t.TempDir()
	source := filepath.Join(directory, "source.txt")
	content := []byte(strings.Repeat(workflow.File.Text, workflow.File.Repeat))
	if err := os.WriteFile(source, content, 0o600); err != nil {
		t.Fatal(err)
	}
	invoke := func(args ...string) string {
		t.Helper()
		stdout, stderr, code := invokeFixtureCLI(fixture, args...)
		if code != 0 {
			t.Fatalf("CLI exit=%d stdout=%s stderr=%s", code, stdout, stderr)
		}
		if strings.Contains(stdout+stderr, fixtureAPIKey) {
			t.Fatal("CLI exposed its API key")
		}
		return stdout
	}
	invoke("create", "--image", workflow.Image)
	invoke("list")
	invoke("inspect", fixtureSandboxID)
	invoke("mkdir", fixtureSandboxID, "src")
	key := uuid.NewString()
	args := []string{"--idempotency-key", key, "exec", fixtureSandboxID, "--"}
	args = append(args, workflow.Command...)
	invoke(args...)
	invoke("job", "list", fixtureSandboxID)
	if !reflect.DeepEqual(fixture.arguments, workflow.Command) || fixture.commandKey != key {
		t.Fatal("CLI rewrote argv or idempotency identity")
	}
	transferID := uuid.NewString()
	invoke("upload", "--transfer-id", transferID, fixtureSandboxID, source, workflow.File.Path)
	if !bytes.Equal(fixture.file, content) || fixture.transfer.State != "committed" {
		t.Fatal("upload did not publish the selected content")
	}
	if fixture.chunkCalls[0] != 1 || len(fixture.chunkCalls) < 2 {
		t.Fatalf("lost acknowledgement duplicated upload: %+v", fixture.chunkCalls)
	}
	invoke("upload", "--transfer-id", transferID, fixtureSandboxID, source, workflow.File.Path)
	if fixture.chunkCalls[0] != 1 {
		t.Fatal("completed upload retry retransmitted bytes")
	}
	output := filepath.Join(directory, "download.txt")
	invoke("download", fixtureSandboxID, workflow.File.Path, output)
	saved, err := os.ReadFile(output)
	if err != nil || !bytes.Equal(saved, content) {
		t.Fatal("download output differs")
	}
	if fixture.downloadCalls < 2 {
		t.Fatal("fixture did not exercise pinned multi-chunk download")
	}
	invoke("stop", fixtureSandboxID)
	invoke("start", fixtureSandboxID)
	invoke("renew", fixtureSandboxID)
	invoke("delete", fixtureSandboxID)
}

func TestDownloadRejectsCorruptionAndMixedVersionsWithoutPublishing(t *testing.T) {
	for _, mode := range []string{"corrupt", "mixed-version", "existing-output"} {
		t.Run(mode, func(t *testing.T) {
			fixture := newWorkflowCoordinator(t)
			fixture.file = bytes.Repeat([]byte("a"), protocol.SandboxMaximumFileChunkBytes+10)
			fixture.corruptChunk = mode == "corrupt"
			fixture.mixedVersion = mode == "mixed-version"
			directory := t.TempDir()
			output := filepath.Join(directory, "result.bin")
			if mode == "existing-output" {
				if err := os.WriteFile(output, []byte("keep existing"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			_, _, code := invokeFixtureCLI(fixture, "download", fixtureSandboxID, "file", output)
			if code == 0 {
				t.Fatal("invalid download succeeded")
			}
			if mode == "existing-output" {
				data, _ := os.ReadFile(output)
				if string(data) != "keep existing" || fixture.downloadCalls != 0 {
					t.Fatal("existing output was modified or download started")
				}
			} else if _, err := os.Stat(output); !os.IsNotExist(err) {
				t.Fatal("failed download published a partial file")
			}
			entries, err := os.ReadDir(directory)
			if err != nil {
				t.Fatal(err)
			}
			for _, entry := range entries {
				if strings.HasPrefix(entry.Name(), ".darkbloom-download-") {
					t.Fatal("partial download staging file leaked")
				}
			}
		})
	}
}

func TestEmptyFileRoundTripAndCommittedAbort(t *testing.T) {
	fixture := newWorkflowCoordinator(t)
	directory := t.TempDir()
	source, output := filepath.Join(directory, "empty-source"), filepath.Join(directory, "empty-output")
	if err := os.WriteFile(source, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	transferID := uuid.NewString()
	if stdout, stderr, code := invokeFixtureCLI(fixture, "upload", "--transfer-id", transferID, fixtureSandboxID, source, "empty"); code != 0 {
		t.Fatalf("empty upload: %d %s %s", code, stdout, stderr)
	}
	if fixture.transfer.State != "committed" || len(fixture.chunkCalls) != 0 {
		t.Fatal("empty upload unexpectedly sent a chunk or failed commit")
	}
	if stdout, stderr, code := invokeFixtureCLI(fixture, "download", fixtureSandboxID, "empty", output); code != 0 {
		t.Fatalf("empty download: %d %s %s", code, stdout, stderr)
	}
	info, err := os.Stat(output)
	if err != nil || info.Size() != 0 {
		t.Fatal("empty download did not publish an empty file")
	}
	stdout, _, code := invokeFixtureCLI(fixture, "upload-abort", fixtureSandboxID, transferID)
	if code == 0 || !strings.Contains(stdout, "upload_already_committed") || fixture.transfer.State != "committed" {
		t.Fatal("abort falsely deleted or aborted a committed upload")
	}
}

func invokeFixtureCLI(fixture *workflowCoordinator, args ...string) (string, string, int) {
	var stdout, stderr bytes.Buffer
	global := []string{"--api-url", fixture.server.URL, "--allow-insecure-localhost", "--json"}
	code := runCLI(context.Background(), append(global, args...), func(name string) string {
		if name == "DARKBLOOM_API_KEY" {
			return fixtureAPIKey
		}
		return ""
	}, &stdout, &stderr)
	return stdout.String(), stderr.String(), code
}
