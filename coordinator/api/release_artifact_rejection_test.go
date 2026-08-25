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
			name:   "missing app main executable",
			layout: releaseBundleTestApp,
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.remove(releaseAppIdentityPayloadSpecs[0].path)
			},
			want: releaseAppIdentityPayloadSpecs[0].path,
		},
		{
			name:   "missing embedded provisioning profile",
			layout: releaseBundleTestApp,
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.remove(releaseAppRequiredDataPayloadSpecs[1].path)
			},
			want: releaseAppRequiredDataPayloadSpecs[1].path,
		},
		{
			name:   "missing app signature envelope",
			layout: releaseBundleTestApp,
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.remove(releaseAppRequiredDataPayloadSpecs[2].path)
			},
			want: releaseAppRequiredDataPayloadSpecs[2].path,
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
			want: "bin/darkbloom\" has mode 0644, want 0755",
		},
		{
			name:   "flat enclave is not executable",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseFlatPayloadSpecs[1].path).mode = 0o644
			},
			want: "bin/darkbloom-enclave\" has mode 0644, want 0755",
		},
		{
			name:   "flat metallib is executable",
			layout: releaseBundleTestLegacy,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseFlatPayloadSpecs[2].path).mode = 0o755
			},
			want: "bin/mlx.metallib\" has mode 0755, want 0644",
		},
		{
			name:   "app binary is not executable",
			layout: releaseBundleTestApp,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseAppPayloadSpecs[0].path).mode = 0o644
			},
			want: "Darkbloom.app/Contents/MacOS/darkbloom\" has mode 0644, want 0755",
		},
		{
			name:   "app enclave is not executable",
			layout: releaseBundleTestApp,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseAppPayloadSpecs[1].path).mode = 0o644
			},
			want: "Darkbloom.app/Contents/MacOS/darkbloom-enclave\" has mode 0644, want 0755",
		},
		{
			name:   "app metallib is executable",
			layout: releaseBundleTestApp,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(t, releaseAppPayloadSpecs[2].path).mode = 0o755
			},
			want: "Darkbloom.app/Contents/MacOS/mlx.metallib\" has mode 0755, want 0644",
		},
		{
			name:   "app main has noncanonical mode",
			layout: releaseBundleTestApp,
			mutate: func(t *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entry(
					t,
					releaseAppIdentityPayloadSpecs[0].path,
				).mode = 0o775
			},
			want: "DarkbloomApp\" has mode 0775, want 0755",
		},
		{
			name:   "unexpected executable beside app binaries",
			layout: releaseBundleTestApp,
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entries = append(
					fixture.entries,
					releaseBundleTestEntry{
						name:     "Darkbloom.app/Contents/MacOS/extra-tool",
						mode:     0o755,
						typeflag: tarTypeReg,
						body:     []byte("unexpected"),
					},
				)
			},
			want: "unexpected payload \"Darkbloom.app/Contents/MacOS/extra-tool\"",
		},
		{
			name:   "unexpected executable app resource",
			layout: releaseBundleTestApp,
			mutate: func(_ *testing.T, fixture *releaseBundleTestFixture) {
				fixture.entries = append(
					fixture.entries,
					releaseBundleTestEntry{
						name:     "Darkbloom.app/Contents/Resources/hidden-tool",
						mode:     0o755,
						typeflag: tarTypeReg,
						body:     []byte("unexpected"),
					},
				)
			},
			want: "unexpected executable payload",
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
