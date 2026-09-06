package api

import (
	"strings"
	"testing"
)

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
			name:   "missing required app launcher",
			layout: releaseBundleTestApp,
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.remove(releaseGUIAppFileSpecs[0].path)
			},
			want: releaseGUIAppFileSpecs[0].path,
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
			name:   "caller cannot assert artifact capability",
			layout: releaseBundleTestLegacy,
			metadata: func(metadata map[string]string) {
				metadata["has_app"] = "true"
			},
			want: `unknown field "has_app"`,
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
			want: "bin/darkbloom\" has mode 0644; expected 0755",
		},
		{
			name:   "flat enclave is not executable",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseFlatPayloadSpecs[1].path).mode = 0o644
			},
			want: "bin/darkbloom-enclave\" has mode 0644; expected 0755",
		},
		{
			name:   "flat metallib is executable",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseFlatPayloadSpecs[2].path).mode = 0o755
			},
			want: "bin/mlx.metallib\" has mode 0755; expected 0644",
		},
		{
			name:   "app binary is not executable",
			layout: releaseBundleTestApp,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseAppPayloadSpecs[0].path).mode = 0o644
			},
			want: "Darkbloom.app/Contents/MacOS/darkbloom\" has mode 0644; expected 0755",
		},
		{
			name:   "app enclave is not executable",
			layout: releaseBundleTestApp,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseAppPayloadSpecs[1].path).mode = 0o644
			},
			want: "Darkbloom.app/Contents/MacOS/darkbloom-enclave\" has mode 0644; expected 0755",
		},
		{
			name:   "app metallib is executable",
			layout: releaseBundleTestApp,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseAppPayloadSpecs[2].path).mode = 0o755
			},
			want: "Darkbloom.app/Contents/MacOS/mlx.metallib\" has mode 0755; expected 0644",
		},
		{
			name:   "flat binary has group write permission",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseFlatPayloadSpecs[0].path).mode = 0o775
			},
			want: "bin/darkbloom\" has mode 0775; expected 0755",
		},
		{
			name:   "flat enclave has owner-only permissions",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseFlatPayloadSpecs[1].path).mode = 0o700
			},
			want: "bin/darkbloom-enclave\" has mode 0700; expected 0755",
		},
		{
			name:   "flat metallib has owner-only permissions",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseFlatPayloadSpecs[2].path).mode = 0o600
			},
			want: "bin/mlx.metallib\" has mode 0600; expected 0644",
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

func TestReleaseRegistrationRejectsIncompleteArtifactCapabilities(t *testing.T) {
	tests := []struct {
		name   string
		binary []byte
		mutate func(*testing.T, *releaseBundleTestFixture)
		want   string
	}{
		{
			name:   "fan code without files",
			binary: []byte(releaseFanCapabilityMarker),
			want:   "fan-helper capability code and artifact files must be present together",
		},
		{
			name: "fan files without code",
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.addArtifactFiles(releaseFanCapabilityFileSpecs)
			},
			want: "fan-helper capability code and artifact files must be present together",
		},
		{
			name:   "fan helper missing",
			binary: []byte(releaseFanCapabilityMarker),
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.addArtifactFiles(releaseFanCapabilityFileSpecs)
				fixture.remove(releaseFanCapabilityFileSpecs[1].path)
			},
			want: "fan-helper capability code and artifact files must be present together",
		},
		{
			name:   "fan marker contents invalid",
			binary: []byte(releaseFanCapabilityMarker),
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.addArtifactFiles(releaseFanCapabilityFileSpecs)
				fixture.entry(
					t,
					releaseFanCapabilityFileSpecs[0].path,
				).body = []byte("0\n")
			},
			want: "fan-helper-v1\" has invalid contents",
		},
		{
			name:   "paged code without files",
			binary: []byte(releasePagedCapabilityMarker),
			want:   "paged-kernel capability code and artifact files must be present together",
		},
		{
			name: "paged files without code",
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.addArtifactFiles(releasePagedCapabilityFileSpecs)
			},
			want: "paged-kernel capability code and artifact files must be present together",
		},
		{
			name:   "paged resource missing",
			binary: []byte(releasePagedCapabilityMarker),
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.addArtifactFiles(releasePagedCapabilityFileSpecs)
				fixture.remove(releasePagedCapabilityFileSpecs[1].path)
			},
			want: "paged-kernel capability code and artifact files must be present together",
		},
		{
			name: "app launcher mode is not exact",
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseGUIAppFileSpecs[0].path).mode = 0o775
			},
			want: "DarkbloomApp\" has mode 0775; expected 0755",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			binary := test.binary
			if len(binary) == 0 {
				binary = []byte("provider-without-runtime-capabilities")
			}
			fixture := newReleaseBundleTestFixture(
				releaseBundleTestApp,
				binary,
			)
			if test.mutate != nil {
				test.mutate(t, fixture)
			}
			result := registerReleaseArtifactForTest(
				t,
				fixture.build(t),
				nil,
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
