package api

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"testing"
)

type releaseBundleTestLayout uint8

const (
	releaseBundleTestLegacy releaseBundleTestLayout = iota
	releaseBundleTestLegacyApp
	releaseBundleTestApp
)

type releaseBundleTestEntry struct {
	name     string
	mode     int64
	typeflag byte
	linkname string
	body     []byte
}

type releaseBundleTestFixture struct {
	entries      []releaseBundleTestEntry
	binaryHash   string
	metallibHash string
}

type releaseBundleTestArtifact struct {
	bytes        []byte
	binaryHash   string
	bundleHash   string
	metallibHash string
}

func newReleaseBundleTestFixture(
	layout releaseBundleTestLayout,
	binary []byte,
) *releaseBundleTestFixture {
	payloads := map[releasePayloadKind][]byte{
		releasePayloadBinary:   append([]byte(nil), binary...),
		releasePayloadEnclave:  []byte("signed-layout-neutral-enclave"),
		releasePayloadMetallib: []byte("signed-layout-neutral-metallib"),
	}
	fixture := &releaseBundleTestFixture{
		binaryHash:   sha256HexBytesForReleaseTest(payloads[releasePayloadBinary]),
		metallibHash: sha256HexBytesForReleaseTest(payloads[releasePayloadMetallib]),
		entries: []releaseBundleTestEntry{
			{name: "bin/", mode: 0o755, typeflag: tar.TypeDir},
			{
				name:     releaseFlatPayloadSpecs[0].path,
				mode:     0o755,
				typeflag: tar.TypeReg,
				body:     append([]byte(nil), payloads[releasePayloadBinary]...),
			},
			{
				name:     releaseFlatPayloadSpecs[1].path,
				mode:     0o755,
				typeflag: tar.TypeReg,
				body:     append([]byte(nil), payloads[releasePayloadEnclave]...),
			},
			{
				name:     releaseFlatPayloadSpecs[2].path,
				mode:     0o644,
				typeflag: tar.TypeReg,
				body:     append([]byte(nil), payloads[releasePayloadMetallib]...),
			},
		},
	}
	if layout != releaseBundleTestLegacy {
		fixture.entries = append(fixture.entries,
			releaseBundleTestEntry{
				name:     "Darkbloom.app/",
				mode:     0o755,
				typeflag: tar.TypeDir,
			},
			releaseBundleTestEntry{
				name:     "Darkbloom.app/Contents/",
				mode:     0o755,
				typeflag: tar.TypeDir,
			},
			releaseBundleTestEntry{
				name:     "Darkbloom.app/Contents/MacOS/",
				mode:     0o755,
				typeflag: tar.TypeDir,
			},
			releaseBundleTestEntry{
				name:     releaseAppPayloadSpecs[0].path,
				mode:     0o755,
				typeflag: tar.TypeReg,
				body:     append([]byte(nil), payloads[releasePayloadBinary]...),
			},
			releaseBundleTestEntry{
				name:     releaseAppPayloadSpecs[1].path,
				mode:     0o755,
				typeflag: tar.TypeReg,
				body:     append([]byte(nil), payloads[releasePayloadEnclave]...),
			},
			releaseBundleTestEntry{
				name:     releaseAppPayloadSpecs[2].path,
				mode:     0o644,
				typeflag: tar.TypeReg,
				body:     append([]byte(nil), payloads[releasePayloadMetallib]...),
			},
		)
		baseGroups := [][]releaseArtifactFileSpec{releaseLegacyAppBaseFileSpecs}
		if layout == releaseBundleTestApp {
			baseGroups = append(baseGroups, releaseGUIAppFileSpecs)
		}
		for _, specs := range baseGroups {
			fixture.addArtifactFiles(specs)
		}
	}
	return fixture
}

func (fixture *releaseBundleTestFixture) addArtifactFiles(
	specs []releaseArtifactFileSpec,
) {
	for _, spec := range specs {
		body := []byte("fixture:" + spec.path)
		if spec.exactContents != "" {
			body = []byte(spec.exactContents)
		}
		fixture.entries = append(
			fixture.entries,
			releaseBundleTestEntry{
				name:     spec.path,
				mode:     spec.mode,
				typeflag: tar.TypeReg,
				body:     body,
			},
		)
	}
}

func (fixture *releaseBundleTestFixture) entry(
	t *testing.T,
	path string,
) *releaseBundleTestEntry {
	t.Helper()
	for index := range fixture.entries {
		if fixture.entries[index].name == path {
			return &fixture.entries[index]
		}
	}
	t.Fatalf("release fixture does not contain %q", path)
	return nil
}

func (fixture *releaseBundleTestFixture) remove(path string) {
	filtered := fixture.entries[:0]
	for _, entry := range fixture.entries {
		if entry.name != path {
			filtered = append(filtered, entry)
		}
	}
	fixture.entries = filtered
}

func (fixture *releaseBundleTestFixture) duplicate(t *testing.T, path string) {
	t.Helper()
	duplicate := *fixture.entry(t, path)
	duplicate.name = "./" + duplicate.name
	duplicate.body = append([]byte(nil), duplicate.body...)
	fixture.entries = append(fixture.entries, duplicate)
}

func (fixture *releaseBundleTestFixture) build(
	t *testing.T,
) releaseBundleTestArtifact {
	t.Helper()
	var output bytes.Buffer
	gzipWriter := gzip.NewWriter(&output)
	tarWriter := tar.NewWriter(gzipWriter)
	for _, entry := range fixture.entries {
		header := &tar.Header{
			Name:     entry.name,
			Mode:     entry.mode,
			Typeflag: entry.typeflag,
			Linkname: entry.linkname,
		}
		if entry.typeflag == tar.TypeReg || entry.typeflag == tar.TypeRegA {
			header.Size = int64(len(entry.body))
		}
		if err := tarWriter.WriteHeader(header); err != nil {
			t.Fatalf("write release fixture header %q: %v", entry.name, err)
		}
		if len(entry.body) > 0 {
			if _, err := tarWriter.Write(entry.body); err != nil {
				t.Fatalf("write release fixture body %q: %v", entry.name, err)
			}
		}
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatalf("close release fixture tar: %v", err)
	}
	if err := gzipWriter.Close(); err != nil {
		t.Fatalf("close release fixture gzip: %v", err)
	}
	return releaseBundleTestArtifact{
		bytes:        output.Bytes(),
		binaryHash:   fixture.binaryHash,
		bundleHash:   sha256HexBytesForReleaseTest(output.Bytes()),
		metallibHash: fixture.metallibHash,
	}
}

func buildReleaseBundleForTest(
	t *testing.T,
	binary []byte,
) releaseBundleTestArtifact {
	t.Helper()
	return newReleaseBundleTestFixture(releaseBundleTestApp, binary).build(t)
}

func buildOversizedReleaseBundleForTest(t *testing.T) releaseBundleTestArtifact {
	t.Helper()
	var output bytes.Buffer
	gzipWriter := gzip.NewWriter(&output)
	tarWriter := tar.NewWriter(gzipWriter)
	if err := tarWriter.WriteHeader(&tar.Header{
		Name: releaseFlatPayloadSpecs[0].path,
		Mode: 0o755,
		Size: maxReleasePayloadBytes + 1,
	}); err != nil {
		t.Fatalf("write oversized release fixture header: %v", err)
	}
	if err := gzipWriter.Close(); err != nil {
		t.Fatalf("close oversized release fixture gzip: %v", err)
	}
	return releaseBundleTestArtifact{
		bytes:      output.Bytes(),
		binaryHash: sha256HexBytesForReleaseTest(nil),
		bundleHash: sha256HexBytesForReleaseTest(output.Bytes()),
		metallibHash: sha256HexBytesForReleaseTest(
			[]byte("signed-layout-neutral-metallib"),
		),
	}
}

func sha256HexBytesForReleaseTest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
