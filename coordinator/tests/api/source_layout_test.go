package api_test

import (
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"strings"
	"testing"
)

func TestAPISourceFilesHaveDeclarations(t *testing.T) {
	for _, root := range []string{"../../api", "../../internal", "."} {
		err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() {
				if entry.Name() == "testdata" {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(path, ".go") || entry.Name() == "doc.go" {
				return nil
			}
			file, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
			if err != nil {
				return err
			}
			if len(file.Decls) == 0 {
				t.Errorf("%s has no declarations; remove the obsolete shell after moving its implementation or tests", path)
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
}
