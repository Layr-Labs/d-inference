package api

import (
	"archive/tar"
	"net/http"
	"strings"
	"testing"
)

func TestReleaseRegistrationDerivesCapabilitiesFromVerifiedArtifact(t *testing.T) {
	tests := []struct {
		name        string
		layout      releaseBundleTestLayout
		binary      []byte
		addPayloads func(*releaseBundleTestFixture)
		wantApp     bool
		wantFan     bool
		wantPaged   bool
	}{
		{
			name:      "legacy flat release",
			layout:    releaseBundleTestLegacy,
			binary:    []byte("legacy provider"),
			wantApp:   false,
			wantFan:   false,
			wantPaged: false,
		},
		{
			name:      "app without optional capabilities",
			layout:    releaseBundleTestApp,
			binary:    []byte("app provider"),
			wantApp:   true,
			wantFan:   false,
			wantPaged: false,
		},
		{
			name:   "app with fan and paged capabilities",
			layout: releaseBundleTestApp,
			binary: []byte(
				"provider darkbloom-fan-helper-v1 engine_v2_kv_backend",
			),
			addPayloads: func(fixture *releaseBundleTestFixture) {
				addReleaseCapabilityPayloads(
					fixture,
					releaseFanCapabilityPayloadSpecs,
					releasePagedCapabilityPayloadSpecs,
				)
			},
			wantApp:   true,
			wantFan:   true,
			wantPaged: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newReleaseBundleTestFixture(test.layout, test.binary)
			if test.addPayloads != nil {
				test.addPayloads(fixture)
			}
			result := registerReleaseArtifactForTest(t, fixture.build(t), nil)
			if result.status != http.StatusOK {
				t.Fatalf(
					"register release: status=%d body=%s",
					result.status,
					result.body,
				)
			}
			if len(result.releases) != 1 {
				t.Fatalf("stored releases=%d, want 1", len(result.releases))
			}
			release := result.releases[0]
			assertDerivedReleaseBool(t, "has_app", release.HasApp, test.wantApp)
			assertDerivedReleaseBool(
				t,
				"has_fan_helper",
				release.HasFanHelper,
				test.wantFan,
			)
			assertDerivedReleaseBool(
				t,
				"has_paged_kernel",
				release.HasPagedKernel,
				test.wantPaged,
			)
		})
	}
}

func TestReleaseRegistrationRejectsCapabilityArtifactMismatch(t *testing.T) {
	tests := []struct {
		name   string
		layout releaseBundleTestLayout
		binary []byte
		mutate func(*releaseBundleTestFixture)
		want   string
	}{
		{
			name:   "fan code without payloads",
			layout: releaseBundleTestApp,
			binary: []byte("darkbloom-fan-helper-v1"),
			want:   "fan helper capability requires matching binary code",
		},
		{
			name:   "fan payloads without code",
			layout: releaseBundleTestApp,
			binary: []byte("provider"),
			mutate: func(fixture *releaseBundleTestFixture) {
				addReleaseCapabilityPayloads(
					fixture,
					releaseFanCapabilityPayloadSpecs,
				)
			},
			want: "fan helper capability requires matching binary code",
		},
		{
			name:   "paged code without payloads",
			layout: releaseBundleTestApp,
			binary: []byte("engine_v2_kv_backend"),
			want:   "paged kernel capability requires matching binary code",
		},
		{
			name:   "paged payloads without code",
			layout: releaseBundleTestApp,
			binary: []byte("provider"),
			mutate: func(fixture *releaseBundleTestFixture) {
				addReleaseCapabilityPayloads(
					fixture,
					releasePagedCapabilityPayloadSpecs,
				)
			},
			want: "paged kernel capability requires matching binary code",
		},
		{
			name:   "invalid fan marker contents",
			layout: releaseBundleTestApp,
			binary: []byte("darkbloom-fan-helper-v1"),
			mutate: func(fixture *releaseBundleTestFixture) {
				addReleaseCapabilityPayloads(
					fixture,
					releaseFanCapabilityPayloadSpecs,
				)
				fixture.entry(
					t,
					releaseFanCapabilityPayloadSpecs[1].path,
				).body = []byte("enabled\n")
			},
			want: "fan-helper-v1\" has invalid contents",
		},
		{
			name:   "fan helper has wrong mode",
			layout: releaseBundleTestApp,
			binary: []byte("darkbloom-fan-helper-v1"),
			mutate: func(fixture *releaseBundleTestFixture) {
				addReleaseCapabilityPayloads(
					fixture,
					releaseFanCapabilityPayloadSpecs,
				)
				fixture.entry(
					t,
					releaseFanCapabilityPayloadSpecs[0].path,
				).mode = 0o775
			},
			want: "darkbloom-fan-helper\" has mode 0775, want 0755",
		},
		{
			name:   "flat fan-capable binary",
			layout: releaseBundleTestLegacy,
			binary: []byte("darkbloom-fan-helper-v1"),
			want:   "capability-bearing provider binaries require the Darkbloom.app layout",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newReleaseBundleTestFixture(test.layout, test.binary)
			if test.mutate != nil {
				test.mutate(fixture)
			}
			result := registerReleaseArtifactForTest(t, fixture.build(t), nil)
			assertReleaseRegistrationRejected(t, result, test.want)
		})
	}
}

func TestReleaseBytePatternScannerMatchesAcrossWrites(t *testing.T) {
	scanner := newReleaseBytePatternScanner("fan-helper-v1")
	for _, chunk := range []string{"prefix fan-", "helper", "-v1 suffix"} {
		if _, err := scanner.Write([]byte(chunk)); err != nil {
			t.Fatalf("scan chunk: %v", err)
		}
	}
	if !scanner.contains("fan-helper-v1") {
		t.Fatal("scanner missed capability split across writes")
	}
	if scanner.contains("missing") {
		t.Fatal("scanner reported an unknown capability")
	}
}

func addReleaseCapabilityPayloads(
	fixture *releaseBundleTestFixture,
	groups ...[]releasePayloadSpec,
) {
	for _, specs := range groups {
		for _, spec := range specs {
			body := []byte("signed capability payload")
			if spec.expectedContent != "" {
				body = []byte(spec.expectedContent)
			}
			fixture.entries = append(fixture.entries, releaseBundleTestEntry{
				name:     spec.path,
				mode:     spec.mode,
				typeflag: tar.TypeReg,
				body:     body,
			})
		}
	}
}

func assertDerivedReleaseBool(
	t *testing.T,
	name string,
	got *bool,
	want bool,
) {
	t.Helper()
	if got == nil {
		t.Fatalf("%s was not derived", name)
	}
	if *got != want {
		t.Fatalf("%s=%t, want %t", name, *got, want)
	}
}

func TestRegisterReleaseRejectsCallerSuppliedCapabilityFlags(t *testing.T) {
	fixture := newReleaseBundleTestFixture(
		releaseBundleTestApp,
		[]byte("provider"),
	)
	result := registerReleaseArtifactForTest(
		t,
		fixture.build(t),
		func(metadata map[string]string) {
			metadata["has_app"] = "false"
		},
	)
	if result.status != http.StatusBadRequest {
		t.Fatalf(
			"caller-supplied capability status=%d, want 400; body=%s",
			result.status,
			result.body,
		)
	}
	if !strings.Contains(result.message, "unknown field") {
		t.Fatalf("message=%q, want unknown field rejection", result.message)
	}
}
