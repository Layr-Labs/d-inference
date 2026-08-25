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
				{
					path: "bin/darkbloom",
					kind: releasePayloadBinary,
					mode: releaseExecutableMode,
				},
				{
					path: "bin/darkbloom-enclave",
					kind: releasePayloadEnclave,
					mode: releaseExecutableMode,
				},
				{
					path: "bin/mlx.metallib",
					kind: releasePayloadMetallib,
					mode: releaseDataMode,
				},
			},
		},
		{
			name: "app",
			got:  releaseAppPayloadSpecs,
			want: []releasePayloadSpec{
				{
					path: "Darkbloom.app/Contents/MacOS/darkbloom",
					kind: releasePayloadBinary,
					mode: releaseExecutableMode,
				},
				{
					path: "Darkbloom.app/Contents/MacOS/darkbloom-enclave",
					kind: releasePayloadEnclave,
					mode: releaseExecutableMode,
				},
				{
					path: "Darkbloom.app/Contents/MacOS/mlx.metallib",
					kind: releasePayloadMetallib,
					mode: releaseDataMode,
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
		name    string
		layout  releaseBundleTestLayout
		wantApp bool
	}{
		{
			name:    "app with flat verifier copies",
			layout:  releaseBundleTestApp,
			wantApp: true,
		},
		{
			name:   "legacy app wrapper with flat verifier copies",
			layout: releaseBundleTestLegacyApp,
		},
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
			if stored.HasApp == nil || *stored.HasApp != test.wantApp {
				t.Fatalf("stored has_app = %v, want %t", stored.HasApp, test.wantApp)
			}
			if stored.HasFanHelper == nil || *stored.HasFanHelper {
				t.Fatalf("stored has_fan_helper = %v, want false", stored.HasFanHelper)
			}
			if stored.HasPagedKernel == nil || *stored.HasPagedKernel {
				t.Fatalf("stored has_paged_kernel = %v, want false", stored.HasPagedKernel)
			}
		})
	}
}

func TestReleaseRegistrationAcceptsPublishedLegacyAppWrapperShape(t *testing.T) {
	binary := []byte(
		"provider:" +
			releaseFanCapabilityMarker + ":" +
			releasePagedCapabilityMarker,
	)
	fixture := newReleaseBundleTestFixture(releaseBundleTestLegacyApp, binary)
	fixture.addArtifactFiles(releaseFanCapabilityFileSpecs)
	fixture.addArtifactFiles(releasePagedCapabilityFileSpecs)

	result := registerReleaseArtifactForTest(t, fixture.build(t), nil)
	if result.status != http.StatusOK {
		t.Fatalf(
			"register legacy app wrapper: status=%d body=%s",
			result.status,
			result.body,
		)
	}
	if len(result.releases) != 1 {
		t.Fatalf("stored releases = %d, want 1", len(result.releases))
	}
	stored := result.releases[0]
	if stored.HasApp == nil || *stored.HasApp {
		t.Fatalf("stored has_app = %v, want false for legacy wrapper", stored.HasApp)
	}
	if stored.HasFanHelper == nil || !*stored.HasFanHelper ||
		stored.HasPagedKernel == nil || !*stored.HasPagedKernel {
		t.Fatalf("stored runtime capabilities are incomplete: %+v", stored)
	}
}

func TestReleaseRegistrationDerivesRuntimeCapabilitiesFromArtifact(t *testing.T) {
	binary := []byte(
		"provider:" +
			releaseFanCapabilityMarker + ":" +
			releasePagedCapabilityMarker,
	)
	fixture := newReleaseBundleTestFixture(releaseBundleTestApp, binary)
	fixture.addArtifactFiles(releaseFanCapabilityFileSpecs)
	fixture.addArtifactFiles(releasePagedCapabilityFileSpecs)

	result := registerReleaseArtifactForTest(t, fixture.build(t), nil)
	if result.status != http.StatusOK {
		t.Fatalf(
			"register capability-complete release: status=%d body=%s",
			result.status,
			result.body,
		)
	}
	if len(result.releases) != 1 {
		t.Fatalf("stored releases = %d, want 1", len(result.releases))
	}
	stored := result.releases[0]
	if stored.HasApp == nil || !*stored.HasApp ||
		stored.HasFanHelper == nil || !*stored.HasFanHelper ||
		stored.HasPagedKernel == nil || !*stored.HasPagedKernel {
		t.Fatalf("stored artifact capabilities are incomplete: %+v", stored)
	}
	for _, field := range []string{
		`"has_app":true`,
		`"has_fan_helper":true`,
		`"has_paged_kernel":true`,
	} {
		if !strings.Contains(result.body, field) {
			t.Fatalf("registration response %s is missing %s", result.body, field)
		}
	}
}

func TestReleaseMarkerScannerFindsMarkersAcrossWriteBoundaries(t *testing.T) {
	scanner := newReleaseMarkerScanner(
		[]byte(releaseFanCapabilityMarker),
		[]byte(releasePagedCapabilityMarker),
	)
	for _, chunk := range [][]byte{
		[]byte("prefix-darkbloom-fan-"),
		[]byte("helper-v1-middle-engine_v2_"),
		[]byte("kv_backend-suffix"),
	} {
		if _, err := scanner.Write(chunk); err != nil {
			t.Fatalf("scanner.Write: %v", err)
		}
	}
	if !scanner.found(0) || !scanner.found(1) {
		t.Fatalf("marker matches = %v, want both true", scanner.matches)
	}
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
