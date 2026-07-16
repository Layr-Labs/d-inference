package testbed

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFindRepositoryRootFromNestedPackageDirectory(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "go.mod"), []byte("module example.test\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "provider-swift"), 0o700); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "e2e", "testbed")
	if err := os.MkdirAll(nested, 0o700); err != nil {
		t.Fatal(err)
	}

	got, err := findRepositoryRoot(nested)
	if err != nil {
		t.Fatal(err)
	}
	if got != root {
		t.Fatalf("repository root = %q, want %q", got, root)
	}
}

func TestFindRepositoryRootRejectsUnrelatedTree(t *testing.T) {
	if _, err := findRepositoryRoot(t.TempDir()); err == nil {
		t.Fatal("unrelated directory unexpectedly resolved as repository root")
	}
}
