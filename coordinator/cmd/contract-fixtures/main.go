// Command contract-fixtures generates and verifies migration contracts shared
// by the Go coordinator, Swift provider, and Rust coordinator.
package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

func main() {
	update := flag.Bool("update", false, "rewrite committed contract fixtures")
	rootFlag := flag.String("root", "", "repository root (auto-detected by default)")
	flag.Parse()

	root, err := repositoryRoot(*rootFlag)
	if err != nil {
		fatal(err)
	}

	generators := []func(string) (map[string][]byte, error){
		generateRoutes,
		generateProtocol,
		generateHTTP,
		generateCrypto,
		generateRouting,
	}

	outputs := make(map[string][]byte)
	for _, generate := range generators {
		generated, err := generate(root)
		if err != nil {
			fatal(err)
		}
		for path, content := range generated {
			if _, exists := outputs[path]; exists {
				fatal(fmt.Errorf("duplicate generated path %s", path))
			}
			outputs[path] = ensureTrailingNewline(content)
		}
	}

	paths := make([]string, 0, len(outputs))
	for path := range outputs {
		paths = append(paths, path)
	}
	sort.Strings(paths)

	var stale []string
	for _, relative := range paths {
		path := filepath.Join(root, relative)
		if *update {
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				fatal(fmt.Errorf("create %s parent: %w", relative, err))
			}
			if err := os.WriteFile(path, outputs[relative], 0o644); err != nil {
				fatal(fmt.Errorf("write %s: %w", relative, err))
			}
			fmt.Printf("updated %s\n", relative)
			continue
		}

		current, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(current, outputs[relative]) {
			stale = append(stale, relative)
		}
	}

	if len(stale) > 0 {
		for _, path := range stale {
			fmt.Fprintf(os.Stderr, "stale contract: %s\n", path)
		}
		fmt.Fprintln(os.Stderr, "run `make contracts-update` and review the contract changes")
		os.Exit(1)
	}
	fmt.Printf("verified %d contract files\n", len(paths))
}

func repositoryRoot(explicit string) (string, error) {
	if explicit != "" {
		return filepath.Abs(explicit)
	}
	dir, err := os.Getwd()
	if err != nil {
		return "", fmt.Errorf("working directory: %w", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("repository root not found from %s", dir)
		}
		dir = parent
	}
}

func ensureTrailingNewline(content []byte) []byte {
	content = bytes.TrimRight(content, "\n")
	return append(content, '\n')
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "contract-fixtures:", err)
	os.Exit(1)
}
