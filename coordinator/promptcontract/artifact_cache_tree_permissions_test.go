package promptcontract

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func openTestRoot(t *testing.T, directory string) *os.Root {
	t.Helper()
	root, err := os.OpenRoot(directory)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		// Restore write access so t.TempDir cleanup can remove the tree.
		_ = makeTreeWritable(root)
		_ = root.Close()
	})
	return root
}

func TestMakeTreeContentsReadOnlyLocksNestedDirectories(t *testing.T) {
	directory := realTempDir(t)
	for _, name := range []string{"a/b", "c"} {
		if err := os.MkdirAll(filepath.Join(directory, name), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(directory, "a", "b", "file"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	root := openTestRoot(t, directory)

	if err := makeTreeContentsReadOnly(root); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"a", "a/b", "c"} {
		info, err := os.Stat(filepath.Join(directory, name))
		if err != nil {
			t.Fatal(err)
		}
		if mode := info.Mode().Perm(); mode != 0o500 {
			t.Fatalf("%s mode = %o, want 500", name, mode)
		}
	}
	// The root itself is left alone so the cache can still rename into it.
	info, err := os.Stat(directory)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm()&0o200 == 0 {
		t.Fatalf("root lost write access: %o", info.Mode().Perm())
	}

	if err := makeTreeWritable(root); err != nil {
		t.Fatal(err)
	}
	info, err = os.Stat(filepath.Join(directory, "a", "b"))
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0o700 {
		t.Fatalf("writable mode = %o, want 700", mode)
	}
}

func TestMakeTreeContentsReadOnlyRejectsSymlinks(t *testing.T) {
	directory := realTempDir(t)
	if err := os.Mkdir(filepath.Join(directory, "sub"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/etc", filepath.Join(directory, "sub", "link")); err != nil {
		t.Fatal(err)
	}
	root := openTestRoot(t, directory)

	err := makeTreeContentsReadOnly(root)
	// The walk error is wrapped as text, so only the outer sentinel is in
	// the chain; the message still names the integrity failure.
	if !errors.Is(err, ErrArtifactUnavailable) || !strings.Contains(err.Error(), ErrArtifactIntegrity.Error()) {
		t.Fatalf("error = %v, want unavailable naming the integrity failure", err)
	}
	if !errors.Is(rejectSymlinks(root), ErrArtifactIntegrity) {
		t.Fatal("rejectSymlinks accepted a symlink")
	}
	// The walk stops before any chmod, so the directory stays writable.
	info, err := os.Stat(filepath.Join(directory, "sub"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o700 {
		t.Fatalf("sub mode = %o, want unchanged 700", info.Mode().Perm())
	}
}
