package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestCommittedContractsAreCurrent(t *testing.T) {
	root, err := repositoryRoot("")
	if err != nil {
		t.Fatal(err)
	}
	generators := []func(string) (map[string][]byte, error){
		generateRoutes,
		generateProtocol,
		generateHTTP,
		generateCrypto,
		generateRouting,
	}
	for _, generate := range generators {
		outputs, err := generate(root)
		if err != nil {
			t.Fatal(err)
		}
		for relative, generated := range outputs {
			generated = ensureTrailingNewline(generated)
			committed, err := os.ReadFile(filepath.Join(root, relative))
			if err != nil {
				t.Fatalf("read %s: %v", relative, err)
			}
			if !bytes.Equal(committed, generated) {
				t.Errorf("%s is stale; run `make contracts-update`", relative)
			}
		}
	}
}
