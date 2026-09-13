package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

func validDigest(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if c < '0' || c > '9' {
			if c < 'a' || c > 'f' {
				return false
			}
		}
	}
	return true
}

func fileDigest(name string) (string, error) {
	file, err := os.Open(name)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func verifyFile(name, expected string) error {
	info, err := os.Lstat(name)
	if err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf("expected regular file %s", filepath.Base(name))
	}
	actual, err := fileDigest(name)
	if err != nil {
		return err
	}
	if actual != expected {
		return fmt.Errorf("digest mismatch: %s", filepath.Base(name))
	}
	return nil
}

func unpackBundle(root string, manifest bundleManifest) error {
	for _, item := range []struct {
		name, prefix, hash string
		limit              int64
	}{
		{"go-sdk.tar.gz", "go", manifest.SDKHash, 4 << 30}, {"source.tar.gz", "source", manifest.SourceHash, 2 << 30},
	} {
		name := filepath.Join(root, item.name)
		if err := verifyFile(name, item.hash); err != nil {
			return err
		}
		if err := unpack(name, root, item.prefix, item.limit); err != nil {
			return err
		}
	}
	return nil
}

// Both trusted packages and locally supplied SDKs still pass strict archive
// boundaries. No symlinks, hard links, devices, duplicates or overwrites.
func unpack(name, root, prefix string, limit int64) (err error) {
	destination := filepath.Join(root, prefix)
	if err := os.Mkdir(destination, 0700); err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = os.RemoveAll(destination)
		}
	}()
	file, err := os.Open(name)
	if err != nil {
		return err
	}
	defer file.Close()
	compressed, err := gzip.NewReader(file)
	if err != nil {
		return err
	}
	defer compressed.Close()
	archive := tar.NewReader(compressed)
	seen := make(map[string]bool)
	var total int64
	for {
		header, readErr := archive.Next()
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return readErr
		}
		clean := strings.TrimSuffix(header.Name, "/")
		if clean == "" || path.Clean(clean) != clean || strings.Contains(clean, "\\") || strings.HasPrefix(clean, "/") ||
			(clean != prefix && !strings.HasPrefix(clean, prefix+"/")) || seen[clean] {
			return errors.New("unsafe or duplicate archive member")
		}
		seen[clean] = true
		if len(seen) > 200000 {
			return errors.New("archive exceeds member count limit")
		}
		name := filepath.Join(root, filepath.FromSlash(clean))
		switch header.Typeflag {
		case tar.TypeDir:
			if clean == prefix {
				continue
			}
			if err := os.MkdirAll(name, 0700); err != nil {
				return err
			}
		case tar.TypeReg, tar.TypeRegA:
			if header.Size < 0 || header.Size > limit-total {
				return errors.New("archive exceeds expanded byte limit")
			}
			total += header.Size
			if err := os.MkdirAll(filepath.Dir(name), 0700); err != nil {
				return err
			}
			mode := os.FileMode(0600)
			if header.Mode&0111 != 0 {
				mode = 0700
			}
			output, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
			if err != nil {
				return err
			}
			_, copyErr := io.CopyN(output, archive, header.Size)
			closeErr := output.Close()
			if copyErr != nil {
				return copyErr
			}
			if closeErr != nil {
				return closeErr
			}
		default:
			return errors.New("archive links and special files are forbidden")
		}
	}
	return nil
}

func packEvidence(directory, destination string) error {
	file, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	compressed := gzip.NewWriter(file)
	archive := tar.NewWriter(compressed)
	err = filepath.WalkDir(directory, func(name string, entry os.DirEntry, walkErr error) error {
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
			return errors.New("evidence contains special file")
		}
		relative, err := filepath.Rel(directory, name)
		if err != nil {
			return err
		}
		header := &tar.Header{Name: filepath.ToSlash(relative), Mode: 0600, Size: info.Size(), Typeflag: tar.TypeReg}
		if err := archive.WriteHeader(header); err != nil {
			return err
		}
		input, err := os.Open(name)
		if err != nil {
			return err
		}
		_, err = io.Copy(archive, input)
		closeErr := input.Close()
		return errors.Join(err, closeErr)
	})
	return errors.Join(err, archive.Close(), compressed.Close(), file.Close())
}
