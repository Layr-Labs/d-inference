package api

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestEmbeddedInstallerMatchesCanonicalSource(t *testing.T) {
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve test source path")
	}
	canonicalPath := filepath.Join(filepath.Dir(currentFile), "..", "..", "scripts", "install.sh")
	canonical, err := os.ReadFile(canonicalPath)
	if err != nil {
		t.Fatalf("read canonical installer: %v", err)
	}
	if !bytes.Equal(canonical, installScript) {
		t.Fatal("embedded installer drifted from scripts/install.sh; run scripts/sync-install-embed.sh")
	}
	if count := bytes.Count(canonical, []byte(installScriptPlaceholder)); count != 1 {
		t.Fatalf("canonical installer contains %d coordinator placeholders, want exactly 1", count)
	}
}
