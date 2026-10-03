package api

// Edge case tests for the coordinator API.
//
// These tests verify that the coordinator handles malformed, missing, and
// boundary-condition inputs gracefully. All tests use mock providers
// (no real backends needed) and run in CI.

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

func buildReleaseBundleForTest(t *testing.T, binary []byte) ([]byte, string, string) {
	t.Helper()

	return buildReleaseBundleWithEntryForTest(t, "bin/darkbloom", tar.TypeReg, binary, "")
}

func buildReleaseBundleWithEntryForTest(t *testing.T, name string, typeflag byte, binary []byte, linkname string) ([]byte, string, string) {
	t.Helper()

	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)

	header := &tar.Header{
		Name:     name,
		Mode:     0o755,
		Typeflag: typeflag,
		Linkname: linkname,
	}
	if typeflag == tar.TypeReg || typeflag == tar.TypeRegA {
		header.Size = int64(len(binary))
	}
	if err := tw.WriteHeader(header); err != nil {
		t.Fatalf("write tar header: %v", err)
	}
	if len(binary) > 0 {
		if _, err := tw.Write(binary); err != nil {
			t.Fatalf("write binary: %v", err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	if err := gz.Close(); err != nil {
		t.Fatalf("close gzip: %v", err)
	}

	return buf.Bytes(), sha256HexBytesForReleaseTest(binary), sha256HexBytesForReleaseTest(buf.Bytes())
}

func sha256HexBytesForReleaseTest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
