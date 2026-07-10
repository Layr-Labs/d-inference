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
