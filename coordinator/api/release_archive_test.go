package api

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestReleaseArchiveLimitsStayInSyncAcrossConsumers(t *testing.T) {
	t.Parallel()
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate release archive test source")
	}
	repositoryRoot := filepath.Clean(
		filepath.Join(filepath.Dir(currentFile), "..", ".."))

	assertFileContainsReleaseLimits(t,
		filepath.Join(repositoryRoot, "scripts", "install.sh"),
		[]string{
			"RELEASE_ARCHIVE_MAX_COMPRESSED_BYTES=2147483648",
			"RELEASE_ARCHIVE_MAX_EXPANDED_BYTES=4294967296",
			"RELEASE_ARCHIVE_MAX_ENTRIES=16384",
			"RELEASE_ARCHIVE_MAX_PATH_BYTES=4096",
			"RELEASE_ARCHIVE_MAX_COMPONENT_BYTES=255",
			"RELEASE_ARCHIVE_MAX_METADATA_BYTES=1048576",
		})
	assertFileContainsReleaseLimits(t,
		filepath.Join(
			repositoryRoot,
			"provider-swift",
			"Sources",
			"ProviderCore",
			"Update",
			"ReleaseArchivePreflight.swift",
		),
		[]string{
			"static let maxCompressedBytes: UInt64 = 2 * 1024 * 1024 * 1024",
			"static let maxExpandedBytes: UInt64 = 4 * 1024 * 1024 * 1024",
			"static let maxEntries = 16 * 1024",
			"static let maxPathBytes = 4 * 1024",
			"static let maxComponentBytes = 255",
			"static let maxMetadataBytes: UInt64 = 1024 * 1024",
		})
}

func TestReleaseArchiveAcceptsPortableBundleAndPAXPath(t *testing.T) {
	longComponent := strings.Repeat("resource-", 15) + "payload"
	longPath := "Darkbloom.app/Contents/Resources/" + longComponent
	archive := buildReleaseArchiveForTest(t,
		releaseArchiveFixture{name: "./", typeflag: tar.TypeDir},
		releaseArchiveFixture{name: "./bin/", typeflag: tar.TypeDir},
		releaseArchiveFixture{name: "./bin/darkbloom", body: []byte("binary")},
		releaseArchiveFixture{name: longPath, body: []byte("resource")},
	)

	var visited []string
	err := validateReleaseArchive(
		bytes.NewReader(archive),
		defaultReleaseArchivePolicy,
		func(entry releaseArchiveEntry, contents io.Reader) error {
			visited = append(visited, entry.Path)
			_, err := io.Copy(io.Discard, contents)
			return err
		},
	)
	if err != nil {
		t.Fatalf("validate portable archive: %v", err)
	}
	if !containsReleaseArchivePath(visited, "bin/darkbloom") {
		t.Fatalf("visitor paths %v do not contain bin/darkbloom", visited)
	}
	if !containsReleaseArchivePath(visited, longPath) {
		t.Fatalf("visitor paths do not contain PAX path %q: %v", longPath, visited)
	}
}

func TestReleaseArchiveAcceptsGNUEncodedLongName(t *testing.T) {
	longPath := "Darkbloom.app/Contents/Resources/" + strings.Repeat("long-name-", 20)
	longPayload := append([]byte(longPath), 0)
	archive := buildRawReleaseArchiveForTest(
		rawReleaseTarEntry{name: "././@LongLink", typeflag: 'L', body: longPayload},
		rawReleaseTarEntry{name: "placeholder", typeflag: '0', body: []byte("resource")},
	)

	var visited string
	err := validateReleaseArchive(
		bytes.NewReader(archive),
		defaultReleaseArchivePolicy,
		func(entry releaseArchiveEntry, _ io.Reader) error {
			visited = entry.Path
			return nil
		},
	)
	if err != nil {
		t.Fatalf("validate GNU long-name archive: %v", err)
	}
	if visited != longPath {
		t.Fatalf("visited path = %q, want %q", visited, longPath)
	}
}

func TestReleaseArchiveRejectsUnsafeDuplicateAndConflictingPaths(t *testing.T) {
	tests := []struct {
		name    string
		archive []byte
		want    string
	}{
		{
			name: "absolute",
			archive: buildRawReleaseArchiveForTest(
				rawReleaseTarEntry{name: "/tmp/escape", typeflag: '0'},
			),
			want: "absolute",
		},
		{
			name: "parent traversal",
			archive: buildRawReleaseArchiveForTest(
				rawReleaseTarEntry{name: "bin/../escape", typeflag: '0'},
			),
			want: "parent traversal",
		},
		{
			name: "backslash",
			archive: buildRawReleaseArchiveForTest(
				rawReleaseTarEntry{name: `bin\darkbloom`, typeflag: '0'},
			),
			want: "backslash",
		},
		{
			name: "duplicate normalized path",
			archive: buildRawReleaseArchiveForTest(
				rawReleaseTarEntry{name: "./bin/darkbloom", typeflag: '0'},
				rawReleaseTarEntry{name: "bin/darkbloom", typeflag: '0'},
			),
			want: "duplicate",
		},
		{
			name: "case conflicting path",
			archive: buildRawReleaseArchiveForTest(
				rawReleaseTarEntry{name: "bin/Darkbloom", typeflag: '0'},
				rawReleaseTarEntry{name: "bin/darkbloom", typeflag: '0'},
			),
			want: "case-conflicting",
		},
		{
			name: "descends through file",
			archive: buildRawReleaseArchiveForTest(
				rawReleaseTarEntry{name: "Darkbloom.app", typeflag: '0'},
				rawReleaseTarEntry{name: "Darkbloom.app/Contents/file", typeflag: '0'},
			),
			want: "descends through file",
		},
		{
			name: "file replaces implicit directory",
			archive: buildRawReleaseArchiveForTest(
				rawReleaseTarEntry{name: "Darkbloom.app/Contents/file", typeflag: '0'},
				rawReleaseTarEntry{name: "Darkbloom.app", typeflag: '0'},
			),
			want: "conflicts with descendant",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateReleaseArchive(
				bytes.NewReader(test.archive),
				defaultReleaseArchivePolicy,
				nil,
			)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("validate error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestReleaseArchiveRejectsUnsupportedNodeTypes(t *testing.T) {
	tests := []struct {
		name     string
		typeflag byte
	}{
		{name: "hard link", typeflag: tar.TypeLink},
		{name: "symbolic link", typeflag: tar.TypeSymlink},
		{name: "character device", typeflag: tar.TypeChar},
		{name: "block device", typeflag: tar.TypeBlock},
		{name: "fifo", typeflag: tar.TypeFifo},
		{name: "contiguous file", typeflag: tar.TypeCont},
		{name: "GNU sparse file", typeflag: tar.TypeGNUSparse},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			archive := buildRawReleaseArchiveForTest(
				rawReleaseTarEntry{name: "dangerous", typeflag: test.typeflag},
			)
			err := validateReleaseArchive(
				bytes.NewReader(archive),
				defaultReleaseArchivePolicy,
				nil,
			)
			if err == nil || !strings.Contains(err.Error(), "unsupported node type") {
				t.Fatalf("validate error = %v, want unsupported node type", err)
			}
		})
	}
}

func TestReleaseArchiveRejectsExpandedSizeBeforeReadingPayload(t *testing.T) {
	sizeField := []byte(fmt.Sprintf("%011o\x00", maxReleaseArchiveExpandedBytes+1))
	archive := buildRawReleaseArchiveForTest(rawReleaseTarEntry{
		name:           "large-sparse-payload",
		typeflag:       '0',
		rawSizeField:   sizeField,
		omitBodyAndPad: true,
	})
	compressed := gzipReleaseArchiveForTest(t, archive)
	if len(compressed) > 4096 {
		t.Fatalf("large-header regression fixture unexpectedly compressed to %d bytes", len(compressed))
	}

	gz, err := gzip.NewReader(bytes.NewReader(compressed))
	if err != nil {
		t.Fatalf("open fixture gzip: %v", err)
	}
	defer gz.Close()
	err = validateReleaseArchive(gz, defaultReleaseArchivePolicy, nil)
	if err == nil || !strings.Contains(err.Error(), "expanded-size limit") {
		t.Fatalf("validate error = %v, want expanded-size limit", err)
	}
}

func TestReleaseArchiveRejectsNegativeAndOverflowingBase256Sizes(t *testing.T) {
	negative := bytes.Repeat([]byte{0xff}, 12)
	overflow := append([]byte{0x80}, bytes.Repeat([]byte{0xff}, 11)...)

	tests := []struct {
		name      string
		sizeField []byte
		want      string
	}{
		{name: "negative", sizeField: negative, want: "negative"},
		{name: "overflow", sizeField: overflow, want: "overflows int64"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			archive := buildRawReleaseArchiveForTest(rawReleaseTarEntry{
				name:           "invalid-size",
				typeflag:       '0',
				rawSizeField:   test.sizeField,
				omitBodyAndPad: true,
			})
			err := validateReleaseArchive(
				bytes.NewReader(archive),
				defaultReleaseArchivePolicy,
				nil,
			)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("validate error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestReleaseArchiveRejectsNonPortableModeBits(t *testing.T) {
	archive := buildRawReleaseArchiveForTest(rawReleaseTarEntry{
		name:         "docs/readme",
		typeflag:     '0',
		rawModeField: []byte("0001000\x00"),
	})
	err := validateReleaseArchive(
		bytes.NewReader(archive),
		defaultReleaseArchivePolicy,
		nil,
	)
	if err == nil || !strings.Contains(err.Error(), "portable permission bits") {
		t.Fatalf("validate error = %v, want portable permission bits", err)
	}
}

func TestReleaseArchiveRejectsDangerousPAXMetadata(t *testing.T) {
	tests := []struct {
		name  string
		key   string
		value string
		want  string
	}{
		{
			name:  "sparse logical size",
			key:   "GNU.sparse.realsize",
			value: "4294967297",
			want:  "unsupported sparse PAX metadata",
		},
		{
			name:  "sun sparse hole map",
			key:   "SUN.holesdata",
			value: "0 4096",
			want:  "unsupported sparse PAX metadata",
		},
		{
			name:  "overflowing size",
			key:   "size",
			value: "999999999999999999999999999999999999",
			want:  "overflows",
		},
		{
			name:  "mode override",
			key:   "SCHILY.mode",
			value: "0000755",
			want:  "unsupported PAX mode metadata",
		},
		{
			name:  "extended attribute",
			key:   "LIBARCHIVE.xattr.user.review",
			value: "cmVzdG9yZWQ=",
			want:  "unsupported PAX metadata key",
		},
		{
			name:  "access control list",
			key:   "SCHILY.acl.access",
			value: "user::rwx",
			want:  "unsupported PAX metadata key",
		},
		{
			name:  "file flags",
			key:   "SCHILY.fflags",
			value: "uchg",
			want:  "unsupported PAX metadata key",
		},
		{
			name:  "link target",
			key:   "linkpath",
			value: "target",
			want:  "unsupported PAX link metadata",
		},
		{
			name:  "unknown semantic",
			key:   "vendor.future",
			value: "value",
			want:  "unsupported PAX metadata key",
		},
		{
			name:  "negative mtime",
			key:   "mtime",
			value: "-1",
			want:  "canonical timestamp",
		},
		{
			name:  "overprecise mtime",
			key:   "mtime",
			value: "1787639300.1234567890",
			want:  "fractional precision",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			pax := releasePAXRecordForTest(test.key, test.value)
			archive := buildRawReleaseArchiveForTest(
				rawReleaseTarEntry{name: "PaxHeaders/file", typeflag: 'x', body: pax},
				rawReleaseTarEntry{name: "file", typeflag: '0'},
			)
			err := validateReleaseArchive(
				bytes.NewReader(archive),
				defaultReleaseArchivePolicy,
				nil,
			)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("validate error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestReleaseArchiveAcceptsStrippedLegacyCodeSignatureMetadata(t *testing.T) {
	keys := []string{
		"LIBARCHIVE.xattr.com.apple.cs.CodeDirectory",
		"LIBARCHIVE.xattr.com.apple.cs.CodeRequirements",
		"LIBARCHIVE.xattr.com.apple.cs.CodeSignature",
		"SCHILY.xattr.com.apple.cs.CodeDirectory",
		"SCHILY.xattr.com.apple.cs.CodeRequirements",
		"SCHILY.xattr.com.apple.cs.CodeSignature",
	}
	for _, key := range keys {
		t.Run(key, func(t *testing.T) {
			pax := append(
				releasePAXRecordForTest(
					"mtime",
					"1787639300.129016206",
				),
				releasePAXRecordForTest(key, "c2lnbmF0dXJl")...,
			)
			archive := buildRawReleaseArchiveForTest(
				rawReleaseTarEntry{
					name:     "PaxHeaders/mlx.metallib",
					typeflag: 'x',
					body:     pax,
				},
				rawReleaseTarEntry{
					name:         "bin/mlx.metallib",
					typeflag:     '0',
					body:         []byte("metal"),
					rawModeField: []byte("0000644\x00"),
				},
			)
			err := validateReleaseArchive(
				bytes.NewReader(archive),
				defaultReleaseArchivePolicy,
				nil,
			)
			if err != nil {
				t.Fatalf("validate legacy code-signature metadata: %v", err)
			}
		})
	}
}

func TestReleaseArchiveEnforcesAggregateExpandedLimit(t *testing.T) {
	archive := buildRawReleaseArchiveForTest(
		rawReleaseTarEntry{name: "first", typeflag: '0', body: []byte("12345678")},
		rawReleaseTarEntry{name: "second", typeflag: '0', body: []byte("abcdefgh")},
	)
	policy := defaultReleaseArchivePolicy
	// Two 512-byte headers plus two padded 512-byte payload regions consume
	// 2048 bytes before the end markers.
	policy.maxExpandedBytes = 4*releaseTarBlockSize - 1

	err := validateReleaseArchive(bytes.NewReader(archive), policy, nil)
	if err == nil || !strings.Contains(err.Error(), "expanded-size limit") {
		t.Fatalf("validate error = %v, want expanded-size limit", err)
	}
}

func TestReleaseArchiveEnforcesExpandedLimitOnZeroTrailer(t *testing.T) {
	archive := buildRawReleaseArchiveForTest(
		rawReleaseTarEntry{name: "empty", typeflag: '0'},
	)
	archive = append(archive, bytes.Repeat([]byte{0}, 2*releaseTarBlockSize)...)
	policy := defaultReleaseArchivePolicy
	// One empty-file header and the two required end markers fit exactly;
	// the additional zero trailer must still be charged.
	policy.maxExpandedBytes = 3 * releaseTarBlockSize

	err := validateReleaseArchive(bytes.NewReader(archive), policy, nil)
	if err == nil || !strings.Contains(err.Error(), "expanded-size limit") {
		t.Fatalf("validate error = %v, want expanded-size limit", err)
	}
}

func TestReleaseArchiveEnforcesPhysicalHeaderCount(t *testing.T) {
	var raw bytes.Buffer
	for index := 0; index <= maxReleaseArchiveEntries; index++ {
		raw.Write(releaseTarHeaderForTest(
			fmt.Sprintf("files/%05d", index),
			'0',
			nil,
			nil,
			0,
		))
	}
	raw.Write(make([]byte, 2*releaseTarBlockSize))
	compressed := gzipReleaseArchiveForTest(t, raw.Bytes())
	if len(compressed) > 512*1024 {
		t.Fatalf("entry-count regression fixture unexpectedly compressed to %d bytes", len(compressed))
	}

	gz, err := gzip.NewReader(bytes.NewReader(compressed))
	if err != nil {
		t.Fatalf("open fixture gzip: %v", err)
	}
	defer gz.Close()
	err = validateReleaseArchive(gz, defaultReleaseArchivePolicy, nil)
	if err == nil || !strings.Contains(err.Error(), "entry limit") {
		t.Fatalf("validate error = %v, want entry limit", err)
	}
}

func TestReleaseArchiveRejectsMalformedHeadersAndTrailingData(t *testing.T) {
	badChecksum := buildRawReleaseArchiveForTest(
		rawReleaseTarEntry{name: "file", typeflag: '0'},
	)
	badChecksum[0] ^= 1

	trailing := buildRawReleaseArchiveForTest(
		rawReleaseTarEntry{name: "file", typeflag: '0'},
	)
	trailing = append(trailing, bytes.Repeat([]byte{1}, releaseTarBlockSize)...)

	tests := []struct {
		name    string
		archive []byte
		want    string
	}{
		{name: "bad checksum", archive: badChecksum, want: "invalid checksum"},
		{name: "non-zero trailer", archive: trailing, want: "non-zero data"},
		{
			name:    "missing end marker",
			archive: releaseTarHeaderForTest("file", '0', nil, nil, 0),
			want:    "missing the tar end marker",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateReleaseArchive(
				bytes.NewReader(test.archive),
				defaultReleaseArchivePolicy,
				nil,
			)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("validate error = %v, want substring %q", err, test.want)
			}
		})
	}
}

type releaseArchiveFixture struct {
	name     string
	typeflag byte
	body     []byte
}

func buildReleaseArchiveForTest(
	t *testing.T,
	fixtures ...releaseArchiveFixture,
) []byte {
	t.Helper()
	var output bytes.Buffer
	writer := tar.NewWriter(&output)
	for _, fixture := range fixtures {
		typeflag := fixture.typeflag
		if typeflag == 0 {
			typeflag = tar.TypeReg
		}
		header := &tar.Header{
			Name:     fixture.name,
			Mode:     0o755,
			Typeflag: typeflag,
		}
		if typeflag == tar.TypeReg || typeflag == tar.TypeRegA {
			header.Size = int64(len(fixture.body))
		}
		if err := writer.WriteHeader(header); err != nil {
			t.Fatalf("write tar header %q: %v", fixture.name, err)
		}
		if len(fixture.body) > 0 {
			if _, err := writer.Write(fixture.body); err != nil {
				t.Fatalf("write tar body %q: %v", fixture.name, err)
			}
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close tar writer: %v", err)
	}
	return output.Bytes()
}

type rawReleaseTarEntry struct {
	name           string
	typeflag       byte
	body           []byte
	rawModeField   []byte
	rawSizeField   []byte
	omitBodyAndPad bool
}

func buildRawReleaseArchiveForTest(entries ...rawReleaseTarEntry) []byte {
	var output bytes.Buffer
	for _, entry := range entries {
		output.Write(releaseTarHeaderForTest(
			entry.name,
			entry.typeflag,
			entry.rawModeField,
			entry.rawSizeField,
			int64(len(entry.body)),
		))
		if entry.omitBodyAndPad {
			continue
		}
		output.Write(entry.body)
		padding := (releaseTarBlockSize - len(entry.body)%releaseTarBlockSize) %
			releaseTarBlockSize
		output.Write(make([]byte, padding))
	}
	output.Write(make([]byte, 2*releaseTarBlockSize))
	return output.Bytes()
}

func releaseTarHeaderForTest(
	name string,
	typeflag byte,
	rawModeField []byte,
	rawSizeField []byte,
	size int64,
) []byte {
	header := make([]byte, releaseTarBlockSize)
	copy(header[0:100], name)
	if rawModeField == nil {
		rawModeField = []byte("0000755\x00")
	}
	copy(header[100:108], rawModeField)
	copy(header[108:116], []byte("0000000\x00"))
	copy(header[116:124], []byte("0000000\x00"))
	if rawSizeField == nil {
		rawSizeField = []byte(fmt.Sprintf("%011o\x00", size))
	}
	copy(header[124:136], rawSizeField)
	copy(header[136:148], []byte("00000000000\x00"))
	for index := 148; index < 156; index++ {
		header[index] = ' '
	}
	header[156] = typeflag
	copy(header[257:263], []byte("ustar\x00"))
	copy(header[263:265], []byte("00"))

	var checksum int64
	for _, value := range header {
		checksum += int64(value)
	}
	copy(header[148:156], []byte(fmt.Sprintf("%06o\x00 ", checksum)))
	return header
}

func releasePAXRecordForTest(key, value string) []byte {
	body := key + "=" + value + "\n"
	length := len(body) + 2
	for {
		record := fmt.Sprintf("%d %s", length, body)
		if len(record) == length {
			return []byte(record)
		}
		length = len(record)
	}
}

func gzipReleaseArchiveForTest(t *testing.T, archive []byte) []byte {
	t.Helper()
	var output bytes.Buffer
	writer := gzip.NewWriter(&output)
	if _, err := writer.Write(archive); err != nil {
		t.Fatalf("gzip fixture: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close fixture gzip: %v", err)
	}
	return output.Bytes()
}

func containsReleaseArchivePath(paths []string, target string) bool {
	for _, candidate := range paths {
		if candidate == target {
			return true
		}
	}
	return false
}

func assertFileContainsReleaseLimits(
	t *testing.T,
	path string,
	expected []string,
) {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read release policy source %s: %v", path, err)
	}
	for _, line := range expected {
		if !bytes.Contains(content, []byte(line)) {
			t.Errorf("%s is missing synchronized archive limit %q", path, line)
		}
	}
}
