package tests_test

import (
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"testing"
)

func TestCoordinatorTestsAreIsolated(t *testing.T) {
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate coordinator test tree")
	}
	violations, err := isolationViolations(filepath.Dir(filepath.Dir(source)))
	if err != nil {
		t.Fatal(err)
	}
	if len(violations) != 0 {
		t.Fatalf("coordinator test isolation violations:\n%s", strings.Join(violations, "\n"))
	}
}

func TestIsolationGuardRejectsProductionTestDependencies(t *testing.T) {
	root := t.TempDir()
	for path, source := range map[string]string{
		"api/owner.go":                     "package api\n",
		"api/owner_test.go":                "package api\n",
		"api/test_support.go":              "package api\nimport \"testing\"\n",
		"api/test_dependency.go":           "package api\nimport \"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit\"\n",
		"tests/api/owner_test.go":          "package api_test\nimport \"testing\"\n",
		"tests/internal/testkit/server.go": "package testkit\nimport \"testing\"\n",
	} {
		filename := filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(filename), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filename, []byte(source), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	got, err := isolationViolations(root)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"api/owner_test.go: test file outside coordinator/tests",
		"api/test_dependency.go: production imports github.com/eigeninference/d-inference/coordinator/tests/internal/testkit",
		"api/test_support.go: production imports testing",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("violations = %v, want %v", got, want)
	}
}

func isolationViolations(root string) ([]string, error) {
	var violations []string
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if path == filepath.Join(root, "tests") || entry.Name() == "target" ||
				entry.Name() == "node_modules" || (path != root && strings.HasPrefix(entry.Name(), ".")) {
				return filepath.SkipDir
			}
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if strings.HasSuffix(path, "_test.go") {
			violations = append(violations, rel+": test file outside coordinator/tests")
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.Contains("/"+rel, "/testdata/") {
			return nil
		}
		file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
		if err != nil {
			return err
		}
		for _, spec := range file.Imports {
			name, err := strconv.Unquote(spec.Path.Value)
			if err != nil {
				return err
			}
			if name == "testing" || strings.HasPrefix(name, "testing/") ||
				name == "github.com/eigeninference/d-inference/coordinator/tests" ||
				strings.HasPrefix(name, "github.com/eigeninference/d-inference/coordinator/tests/") {
				violations = append(violations, rel+": production imports "+name)
			}
		}
		return nil
	})
	sort.Strings(violations)
	return violations, err
}
