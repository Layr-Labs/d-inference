package main

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func makeArchive(t *testing.T, name string, headers []*tar.Header, contents []string) {
	t.Helper()
	file, err := os.Create(name)
	if err != nil {
		t.Fatal(err)
	}
	gz := gzip.NewWriter(file)
	archive := tar.NewWriter(gz)
	for index, header := range headers {
		if err := archive.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if contents[index] != "" {
			if _, err := archive.Write([]byte(contents[index])); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := errors.Join(archive.Close(), gz.Close(), file.Close()); err != nil {
		t.Fatal(err)
	}
}

func TestUnpackRejectsLinksTraversalDuplicatesAndExpansion(t *testing.T) {
	for _, name := range []string{"../escape", "go/../../escape", "/absolute", "source/wrong", "go//double"} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			archive := filepath.Join(root, "sdk.tar.gz")
			makeArchive(t, archive, []*tar.Header{{Name: name, Typeflag: tar.TypeReg, Size: 1}}, []string{"x"})
			if err := unpack(archive, root, "go", 32); err == nil {
				t.Fatal("unsafe path accepted")
			}
			if _, err := os.Stat(filepath.Join(root, "go")); !os.IsNotExist(err) {
				t.Fatal("partial unsafe tree retained")
			}
		})
	}
	for _, kind := range []byte{tar.TypeSymlink, tar.TypeLink, tar.TypeFifo} {
		root := t.TempDir()
		archive := filepath.Join(root, "sdk.tar.gz")
		makeArchive(t, archive, []*tar.Header{{Name: "go/link", Typeflag: kind, Linkname: "../outside"}}, []string{""})
		if err := unpack(archive, root, "go", 32); err == nil {
			t.Fatal("special file accepted")
		}
	}
	for _, limit := range []int64{0, 32} {
		root := t.TempDir()
		archive := filepath.Join(root, "sdk.tar.gz")
		makeArchive(t, archive, []*tar.Header{{Name: "go/file", Typeflag: tar.TypeReg, Size: 1}, {Name: "go/file", Typeflag: tar.TypeReg, Size: 1}}, []string{"x", "y"})
		if err := unpack(archive, root, "go", limit); err == nil {
			t.Fatal("duplicate or oversized archive accepted")
		}
	}
}

func TestUnpackPreservesExecutableAndRefusesOverwrite(t *testing.T) {
	root := t.TempDir()
	archive := filepath.Join(root, "sdk.tar.gz")
	makeArchive(t, archive, []*tar.Header{{Name: "go/bin/go", Typeflag: tar.TypeReg, Mode: 0755, Size: 1}}, []string{"x"})
	if err := unpack(archive, root, "go", 32); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(root, "go/bin/go"))
	if err != nil || info.Mode()&0111 == 0 {
		t.Fatal("SDK executable lost mode")
	}
	if err := unpack(archive, root, "go", 32); err == nil {
		t.Fatal("existing extracted SDK overwritten")
	}
}

func TestInputTreeDigestDetectsChangedContentAndExecutableMode(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "go")
	if err := os.WriteFile(file, []byte("original"), 0700); err != nil {
		t.Fatal(err)
	}
	before, err := treeDigest(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(file, 0600); err != nil {
		t.Fatal(err)
	}
	after, _ := treeDigest(root)
	if before == after {
		t.Fatal("executable mutation not detected")
	}
	if err := os.WriteFile(file, []byte("changed"), 0600); err != nil {
		t.Fatal(err)
	}
	changed, _ := treeDigest(root)
	if changed == after {
		t.Fatal("content mutation not detected")
	}
	if err := os.Symlink(file, filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	if _, err := treeDigest(root); err == nil {
		t.Fatal("input symlink accepted")
	}
}

func TestEnvironmentDoesNotInheritCredentialsDatabaseOrUserCache(t *testing.T) {
	t.Setenv("DATABASE_URL", "production-database")
	t.Setenv("DARKBLOOM_API_KEY", "secret")
	t.Setenv("GOCACHE", "user-cache")
	environment := workloadEnvironment("/workspace/ci", "/workspace/run", bundleManifest{GOOS: "darwin", GOARCH: "arm64", GOMAXPROCS: 4})
	joined := strings.Join(environment, "\n")
	for _, forbidden := range []string{"production-database", "secret", "user-cache", "DATABASE_URL", "DARKBLOOM_API_KEY"} {
		if strings.Contains(joined, forbidden) {
			t.Fatalf("inherited %s", forbidden)
		}
	}
	for _, required := range []string{"GOTOOLCHAIN=local", "GOPROXY=off", "GOSUMDB=off", "GOFLAGS=-mod=vendor", "CGO_ENABLED=0", "GOMAXPROCS=4", "GOCACHE=/workspace/run/cache"} {
		if !strings.Contains(joined, required) {
			t.Fatalf("missing %s", required)
		}
	}
}

func TestUnitEvidenceRequiresCasesAndTerminalPackagePass(t *testing.T) {
	for _, events := range [][]map[string]string{
		{{"Action": "pass", "Package": "package", "Test": "TestOne"}},
		{{"Action": "pass", "Package": "package"}},
		{{"Action": "skip", "Package": "package", "Test": "TestOne"}, {"Action": "pass", "Package": "package"}},
		{{"Action": "fail", "Package": "package", "Test": "TestOne"}},
	} {
		name := filepath.Join(t.TempDir(), "tests.jsonl")
		file, _ := os.Create(name)
		for _, event := range events {
			_ = json.NewEncoder(file).Encode(event)
		}
		_ = file.Close()
		if _, err := readTestOutcome(name, "package"); err == nil {
			t.Fatal("incomplete/failed test evidence accepted")
		}
	}
}

func TestInvocationUsesExplicitPackageDirectoryAndHonorsDeadline(t *testing.T) {
	root := t.TempDir()
	expected, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(root, "pwd.log")
	if _, err := invoke(context.Background(), root, []string{"PATH=/usr/bin:/bin"}, []string{"/bin/pwd"}, log); err != nil {
		t.Fatal(err)
	}
	actual, err := os.ReadFile(log)
	if err != nil || strings.TrimSpace(string(actual)) != expected {
		t.Fatalf("wrong fixture cwd: %s %v", actual, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	started := time.Now()
	if _, err := invoke(ctx, root, nil, []string{"/bin/sleep", "30"}, filepath.Join(root, "sleep.log")); err == nil {
		t.Fatal("deadline ignored")
	}
	if time.Since(started) > time.Second {
		t.Fatal("timed out workload process survived")
	}
}
