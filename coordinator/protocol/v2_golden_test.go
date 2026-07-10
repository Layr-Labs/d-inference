package protocol

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func goldenDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("caller")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", "coordinator-rs", "tests", "protocol"))
}

func TestV2Goldens_ProviderToCoordinator(t *testing.T) {
	dir := goldenDir(t)
	for _, name := range []string{"prepared.json", "provider_terminal.json"} {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		var pm ProviderMessage
		if err := json.Unmarshal(b, &pm); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if pm.Type == "" || pm.Payload == nil {
			t.Fatalf("%s: empty decode type=%q payload=%T", name, pm.Type, pm.Payload)
		}
	}
}

func TestV2Goldens_PrepareCommand(t *testing.T) {
	dir := goldenDir(t)
	b, err := os.ReadFile(filepath.Join(dir, "prepare.json"))
	if err != nil {
		t.Fatal(err)
	}
	var msg PrepareMessage
	if err := json.Unmarshal(b, &msg); err != nil {
		t.Fatal(err)
	}
	if msg.Type != TypePrepare || msg.Model == "" || msg.JobID == "" {
		t.Fatalf("unexpected prepare: %+v", msg)
	}
}

func TestV2Goldens_StartAbortCommands(t *testing.T) {
	dir := goldenDir(t)
	{
		b, err := os.ReadFile(filepath.Join(dir, "start.json"))
		if err != nil {
			t.Fatal(err)
		}
		var msg StartMessage
		if err := json.Unmarshal(b, &msg); err != nil {
			t.Fatal(err)
		}
		if msg.Type != TypeStart || msg.LeaseID == "" {
			t.Fatalf("start: %+v", msg)
		}
	}
	{
		b, err := os.ReadFile(filepath.Join(dir, "abort.json"))
		if err != nil {
			t.Fatal(err)
		}
		var msg AbortMessage
		if err := json.Unmarshal(b, &msg); err != nil {
			t.Fatal(err)
		}
		if msg.Type != TypeAbort || msg.Reason != "hedge_lost" {
			t.Fatalf("abort: %+v", msg)
		}
	}
}

func TestV2Goldens_TerminalAck(t *testing.T) {
	dir := goldenDir(t)
	b, err := os.ReadFile(filepath.Join(dir, "terminal_ack.json"))
	if err != nil {
		t.Fatal(err)
	}
	var msg TerminalAckMessage
	if err := json.Unmarshal(b, &msg); err != nil {
		t.Fatal(err)
	}
	if msg.Type != TypeTerminalAck || msg.Disposition != "settled" {
		t.Fatalf("terminal_ack: %+v", msg)
	}
}

func TestV2Goldens_Cancelled(t *testing.T) {
	dir := goldenDir(t)
	b, err := os.ReadFile(filepath.Join(dir, "cancelled.json"))
	if err != nil {
		t.Fatal(err)
	}
	var pm ProviderMessage
	if err := json.Unmarshal(b, &pm); err != nil {
		t.Fatal(err)
	}
	if pm.Type != TypeCancelled {
		t.Fatalf("type=%q", pm.Type)
	}
	if _, ok := pm.Payload.(*CancelledMessage); !ok {
		t.Fatalf("payload=%T", pm.Payload)
	}
}

func TestV2Goldens_ModelLifecycle(t *testing.T) {
	dir := goldenDir(t)
	for _, name := range []string{"model_ready.json", "model_gone.json"} {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatal(err)
		}
		var pm ProviderMessage
		if err := json.Unmarshal(b, &pm); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		switch name {
		case "model_ready.json":
			if pm.Type != TypeModelReady {
				t.Fatalf("type=%q", pm.Type)
			}
			if _, ok := pm.Payload.(*ModelReadyMessage); !ok {
				t.Fatalf("payload=%T", pm.Payload)
			}
		case "model_gone.json":
			if pm.Type != TypeModelGone {
				t.Fatalf("type=%q", pm.Type)
			}
			if _, ok := pm.Payload.(*ModelGoneMessage); !ok {
				t.Fatalf("payload=%T", pm.Payload)
			}
		}
	}
}
