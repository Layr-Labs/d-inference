package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type releaseRegistrationTestResult struct {
	status   int
	body     string
	message  string
	releases []store.Release
}

func TestReleasePayloadSpecsMatchInstallerLayouts(t *testing.T) {
	tests := []struct {
		name string
		got  []releasePayloadSpec
		want []releasePayloadSpec
	}{
		{
			name: "legacy flat",
			got:  releaseFlatPayloadSpecs,
			want: []releasePayloadSpec{
				{path: "bin/darkbloom", kind: releasePayloadBinary, executable: true},
				{path: "bin/darkbloom-enclave", kind: releasePayloadEnclave, executable: true},
				{path: "bin/mlx.metallib", kind: releasePayloadMetallib},
			},
		},
		{
			name: "app",
			got:  releaseAppPayloadSpecs,
			want: []releasePayloadSpec{
				{
					path:       "Darkbloom.app/Contents/MacOS/darkbloom",
					kind:       releasePayloadBinary,
					executable: true,
				},
				{
					path:       "Darkbloom.app/Contents/MacOS/darkbloom-enclave",
					kind:       releasePayloadEnclave,
					executable: true,
				},
				{
					path: "Darkbloom.app/Contents/MacOS/mlx.metallib",
					kind: releasePayloadMetallib,
				},
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if len(test.got) != len(test.want) {
				t.Fatalf("payload spec count=%d, want %d", len(test.got), len(test.want))
			}
			for index := range test.want {
				if test.got[index] != test.want[index] {
					t.Fatalf(
						"payload spec %d=%+v, want %+v",
						index,
						test.got[index],
						test.want[index],
					)
				}
			}
		})
	}
}

func TestReleaseRegistrationAcceptsAppAndLegacyBundleLayouts(t *testing.T) {
	tests := []struct {
		name   string
		layout releaseBundleTestLayout
	}{
		{name: "app with flat verifier copies", layout: releaseBundleTestApp},
		{name: "legacy flat bundle", layout: releaseBundleTestLegacy},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newReleaseBundleTestFixture(
				test.layout,
				[]byte("signed-layout-neutral-provider"),
			)
			if test.layout == releaseBundleTestLegacy {
				fixture.entry(t, releaseFlatPayloadSpecs[0].path).typeflag = tarTypeRegA
			}
			artifact := fixture.build(t)
			result := registerReleaseArtifactForTest(t, artifact, nil)
			if result.status != http.StatusOK {
				t.Fatalf(
					"register valid release: status=%d body=%s",
					result.status,
					result.body,
				)
			}
			if len(result.releases) != 1 {
				t.Fatalf("stored releases = %d, want 1", len(result.releases))
			}
			stored := result.releases[0]
			if stored.BinaryHash != artifact.binaryHash ||
				stored.MetallibHash != artifact.metallibHash ||
				stored.BundleHash != artifact.bundleHash {
				t.Fatalf("stored release hashes do not match verified artifact: %+v", stored)
			}
		})
	}
}

func TestReleaseRegistrationRejectsInvalidPayloadsBeforePersistence(t *testing.T) {
	tests := []struct {
		name     string
		layout   releaseBundleTestLayout
		mutate   func(*testing.T, *releaseBundleTestFixture)
		metadata func(map[string]string)
		want     string
	}{
		{
			name:   "missing flat darkbloom",
			layout: releaseBundleTestLegacy,
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.remove(releaseFlatPayloadSpecs[0].path)
			},
			want: releaseFlatPayloadSpecs[0].path,
		},
		{
			name:   "missing flat enclave",
			layout: releaseBundleTestLegacy,
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.remove(releaseFlatPayloadSpecs[1].path)
			},
			want: releaseFlatPayloadSpecs[1].path,
		},
		{
			name:   "missing flat metallib",
			layout: releaseBundleTestLegacy,
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.remove(releaseFlatPayloadSpecs[2].path)
			},
			want: releaseFlatPayloadSpecs[2].path,
		},
		{
			name:   "missing app darkbloom",
			layout: releaseBundleTestApp,
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.remove(releaseAppPayloadSpecs[0].path)
			},
			want: releaseAppPayloadSpecs[0].path,
		},
		{
			name:   "missing app enclave",
			layout: releaseBundleTestApp,
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.remove(releaseAppPayloadSpecs[1].path)
			},
			want: releaseAppPayloadSpecs[1].path,
		},
		{
			name:   "missing app metallib",
			layout: releaseBundleTestApp,
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.remove(releaseAppPayloadSpecs[2].path)
			},
			want: releaseAppPayloadSpecs[2].path,
		},
		{
			name:   "empty binary",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseFlatPayloadSpecs[0].path).body = nil
				fixture.binaryHash = sha256HexBytesForReleaseTest(nil)
			},
			want: "bin/darkbloom\" is empty",
		},
		{
			name:   "empty enclave",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseFlatPayloadSpecs[1].path).body = nil
			},
			want: "bin/darkbloom-enclave\" is empty",
		},
		{
			name:   "empty metallib",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseFlatPayloadSpecs[2].path).body = nil
				fixture.metallibHash = sha256HexBytesForReleaseTest(nil)
			},
			want: "bin/mlx.metallib\" is empty",
		},
		{
			name:   "registered binary hash mismatch",
			layout: releaseBundleTestLegacy,
			metadata: func(metadata map[string]string) {
				metadata["binary_hash"] = strings.Repeat("a", 64)
			},
			want: "binary_hash does not match",
		},
		{
			name:   "registered metallib hash mismatch",
			layout: releaseBundleTestLegacy,
			metadata: func(metadata map[string]string) {
				metadata["metallib_hash"] = strings.Repeat("b", 64)
			},
			want: "metallib_hash does not match",
		},
		{
			name:   "app binary differs from flat copy",
			layout: releaseBundleTestApp,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseAppPayloadSpecs[0].path).body =
					[]byte("different-app-binary")
			},
			want: "app and flat copies of darkbloom do not match",
		},
		{
			name:   "app enclave differs from flat copy",
			layout: releaseBundleTestApp,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseAppPayloadSpecs[1].path).body =
					[]byte("different-app-enclave")
			},
			want: "app and flat copies of darkbloom-enclave do not match",
		},
		{
			name:   "app metallib differs from flat copy",
			layout: releaseBundleTestApp,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseAppPayloadSpecs[2].path).body =
					[]byte("different-app-metallib")
			},
			want: "app and flat copies of mlx.metallib do not match",
		},
		{
			name:   "duplicate payload",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.duplicate(t, releaseFlatPayloadSpecs[0].path)
			},
			want: "duplicate or case-conflicting path",
		},
		{
			name:   "binary is symbolic link",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				entry := fixture.entry(t, releaseFlatPayloadSpecs[0].path)
				entry.typeflag = tarTypeSymlink
				entry.linkname = "darkbloom.real"
				entry.body = nil
			},
			want: "unsupported node type",
		},
		{
			name:   "enclave is directory",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				entry := fixture.entry(t, releaseFlatPayloadSpecs[1].path)
				entry.typeflag = tarTypeDir
				entry.body = nil
			},
			want: "is not a regular file",
		},
		{
			name:   "metallib is FIFO",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				entry := fixture.entry(t, releaseFlatPayloadSpecs[2].path)
				entry.typeflag = tarTypeFifo
				entry.body = nil
			},
			want: "unsupported node type",
		},
		{
			name:   "flat binary is not executable",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseFlatPayloadSpecs[0].path).mode = 0o644
			},
			want: "bin/darkbloom\" is not executable",
		},
		{
			name:   "flat enclave is not executable",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseFlatPayloadSpecs[1].path).mode = 0o644
			},
			want: "bin/darkbloom-enclave\" is not executable",
		},
		{
			name:   "flat metallib is executable",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseFlatPayloadSpecs[2].path).mode = 0o755
			},
			want: "bin/mlx.metallib\" must not be executable",
		},
		{
			name:   "app binary is not executable",
			layout: releaseBundleTestApp,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseAppPayloadSpecs[0].path).mode = 0o644
			},
			want: "Darkbloom.app/Contents/MacOS/darkbloom\" is not executable",
		},
		{
			name:   "app enclave is not executable",
			layout: releaseBundleTestApp,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseAppPayloadSpecs[1].path).mode = 0o644
			},
			want: "Darkbloom.app/Contents/MacOS/darkbloom-enclave\" is not executable",
		},
		{
			name:   "app metallib is executable",
			layout: releaseBundleTestApp,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseAppPayloadSpecs[2].path).mode = 0o755
			},
			want: "Darkbloom.app/Contents/MacOS/mlx.metallib\" must not be executable",
		},
		{
			name:   "unsafe archive path",
			layout: releaseBundleTestLegacy,
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entries = append(fixture.entries, releaseBundleTestEntry{
					name:     "../escape",
					mode:     0o644,
					typeflag: tarTypeReg,
				})
			},
			want: "parent traversal",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newReleaseBundleTestFixture(
				test.layout,
				[]byte("signed-layout-neutral-provider"),
			)
			if test.mutate != nil {
				test.mutate(t, fixture)
			}
			result := registerReleaseArtifactForTest(
				t,
				fixture.build(t),
				test.metadata,
			)
			assertReleaseRegistrationRejected(t, result, test.want)
		})
	}
}

func TestReleaseRegistrationRejectsBundleAndPayloadBoundsBeforePersistence(t *testing.T) {
	valid := newReleaseBundleTestFixture(
		releaseBundleTestLegacy,
		[]byte("signed-layout-neutral-provider"),
	).build(t)
	bundleMismatch := registerReleaseArtifactForTest(
		t,
		valid,
		func(metadata map[string]string) {
			metadata["bundle_hash"] = strings.Repeat("c", 64)
		},
	)
	assertReleaseRegistrationRejected(
		t,
		bundleMismatch,
		"bundle_hash does not match",
	)

	oversized := registerReleaseArtifactForTest(
		t,
		buildOversizedReleaseBundleForTest(t),
		nil,
	)
	assertReleaseRegistrationRejected(
		t,
		oversized,
		"exceeds the 536870912-byte limit",
	)
}

func registerReleaseArtifactForTest(
	t *testing.T,
	artifact releaseBundleTestArtifact,
	mutateMetadata func(map[string]string),
) releaseRegistrationTestResult {
	t.Helper()
	const artifactPath = "/releases/v1.0.0/darkbloom-bundle-macos-arm64.tar.gz"

	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != artifactPath {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(artifact.bytes)
	}))
	defer cdn.Close()

	srv, st := testServer(t)
	srv.SetReleaseKey("release-key")
	srv.SetR2CDNURL(cdn.URL)
	apiServer := httptest.NewServer(srv.Handler())
	defer apiServer.Close()

	metadata := map[string]string{
		"version":       "1.0.0",
		"platform":      "macos-arm64",
		"backend":       "mlx-swift",
		"binary_hash":   artifact.binaryHash,
		"bundle_hash":   artifact.bundleHash,
		"metallib_hash": artifact.metallibHash,
		"url":           cdn.URL + artifactPath,
		"changelog":     "artifact integrity test",
	}
	if mutateMetadata != nil {
		mutateMetadata(metadata)
	}
	body, err := json.Marshal(metadata)
	if err != nil {
		t.Fatalf("marshal release registration: %v", err)
	}
	req, err := http.NewRequest(
		http.MethodPost,
		apiServer.URL+"/v1/releases",
		bytes.NewReader(body),
	)
	if err != nil {
		t.Fatalf("create release registration request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer release-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("register release: %v", err)
	}
	defer resp.Body.Close()
	responseBody, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read release registration response: %v", err)
	}
	var envelope struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	_ = json.Unmarshal(responseBody, &envelope)
	return releaseRegistrationTestResult{
		status:   resp.StatusCode,
		body:     string(responseBody),
		message:  envelope.Error.Message,
		releases: st.ListReleases(),
	}
}

func assertReleaseRegistrationRejected(
	t *testing.T,
	result releaseRegistrationTestResult,
	want string,
) {
	t.Helper()
	if result.status != http.StatusBadRequest {
		t.Fatalf(
			"release registration status=%d, want 400; body=%s",
			result.status,
			result.body,
		)
	}
	if !strings.Contains(result.message, want) {
		t.Fatalf(
			"release registration message=%q, want substring %q; body=%s",
			result.message,
			want,
			result.body,
		)
	}
	if len(result.releases) != 0 {
		t.Fatalf("invalid release persisted before rejection: %+v", result.releases)
	}
}

const (
	tarTypeRegA    = byte(0)
	tarTypeReg     = byte('0')
	tarTypeSymlink = byte('2')
	tarTypeDir     = byte('5')
	tarTypeFifo    = byte('6')
)
