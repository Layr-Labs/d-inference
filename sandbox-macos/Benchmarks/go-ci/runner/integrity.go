package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

func treeDigest(root string) (string, error) {
	var names []string
	err := filepath.WalkDir(root, func(name string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return errors.New("input tree contains special file")
		}
		names = append(names, name)
		if len(names) > 200000 {
			return errors.New("input tree has too many files")
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	sort.Strings(names)
	hash := sha256.New()
	for _, name := range names {
		info, err := os.Lstat(name)
		if err != nil {
			return "", err
		}
		digest, err := fileDigest(name)
		if err != nil {
			return "", err
		}
		relative, err := filepath.Rel(root, name)
		if err != nil {
			return "", err
		}
		executable := 0
		if info.Mode()&0111 != 0 {
			executable = 1
		}
		fmt.Fprintf(hash, "%s\x00%s\x00%d\x00%d\n", filepath.ToSlash(relative), digest, info.Size(), executable)
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func verifyInputTrees(root string, manifest bundleManifest) error {
	for _, item := range []struct{ name, expected string }{{"go", manifest.SDKTreeHash}, {"source", manifest.SourceTreeHash}} {
		actual, err := treeDigest(filepath.Join(root, item.name))
		if err != nil {
			return err
		}
		if actual != item.expected {
			return fmt.Errorf("extracted %s inputs changed", item.name)
		}
	}
	return nil
}
