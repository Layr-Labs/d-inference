package releases

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"strings"
	"testing"
)

func TestRuntimeManifestUnionsPerFamilyTemplateHashes(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	srv := releaseOwnerFixture(registry.New(quietLogger()), st, quietLogger())
	qwenOld, qwenNew, qwenUnknown := strings.Repeat("1", 64), strings.Repeat("2", 64), strings.Repeat("3", 64)
	gemmaShared := strings.Repeat("6", 64)

	older := testRelease("0.8.15", trHashA)
	older.TemplateHashes = "qwen3.5=" + qwenOld + ",gemma4=" + gemmaShared
	newer := testRelease("0.8.16", trHashB)
	newer.TemplateHashes = "qwen3.5=" + qwenNew + ",gemma4=" + gemmaShared
	for _, rel := range []*store.Release{older, newer} {
		if err := st.SetRelease(rel); err != nil {
			t.Fatalf("SetRelease(%s): %v", rel.Version, err)
		}
	}
	if err := srv.SyncRuntimeManifest(); err != nil {
		t.Fatalf("SyncRuntimeManifest: %v", err)
	}
	manifest := srv.RuntimeManifest()
	if got := manifest.TemplateHashes["qwen3.5"]; len(got) != 2 || !got[qwenOld] || !got[qwenNew] {
		t.Fatalf("qwen3.5 accepted set = %v, want both releases' values", got)
	}
	if got := manifest.TemplateHashes["gemma4"]; len(got) != 1 || !got[gemmaShared] {
		t.Fatalf("gemma4 accepted set = %v, want the single shared value", got)
	}

	report := func(qwen string) map[string]string {
		return map[string]string{"qwen3.5": qwen, "gemma4": gemmaShared, "mlx_metallib": trHashC}
	}
	cases := []struct {
		name   string
		qwen   string
		wantOK bool
	}{
		{"older release's family template", qwenOld, true},
		{"newer release's family template", qwenNew, true},
		{"family template no active release ships", qwenUnknown, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ok, mismatches := manifest.verifyReportedHashes(report(tc.qwen))
			if ok != tc.wantOK {
				t.Fatalf("verify = %v (%+v), want %v", ok, mismatches, tc.wantOK)
			}
			if !tc.wantOK && (len(mismatches) != 1 || mismatches[0].Component != "template:qwen3.5") {
				t.Fatalf("mismatches = %+v, want exactly one qwen3.5 mismatch", mismatches)
			}
		})
	}

	// Deactivating the older release removes only its value.
	if err := st.DeleteRelease("0.8.15", "macos-arm64"); err != nil {
		t.Fatalf("DeleteRelease: %v", err)
	}
	if err := srv.SyncRuntimeManifest(); err != nil {
		t.Fatalf("SyncRuntimeManifest after deactivation: %v", err)
	}
	manifest = srv.RuntimeManifest()
	if got := manifest.TemplateHashes["qwen3.5"]; len(got) != 1 || !got[qwenNew] {
		t.Fatalf("qwen3.5 accepted set after deactivation = %v, want only the newer value", got)
	}
	if ok, _ := manifest.verifyReportedHashes(report(qwenOld)); ok {
		t.Fatal("deactivated release's family template must no longer be accepted")
	}
	if ok, mismatches := manifest.verifyReportedHashes(report(qwenNew)); !ok {
		t.Fatalf("remaining release's family template must still be accepted: %+v", mismatches)
	}
}

// registerReleaseWithMetallibForTest registers a release through the real
// POST /v1/releases handler (artifact verification against the fake CDN
// included) with a caller-chosen metallib hash and production-shape family
// template hashes.
