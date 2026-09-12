package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// These tests pin the 2026-09-03 release brownout. Registering provider release
// v0.8.16 rebuilt the runtime manifest with a SINGLE mlx_metallib value (the
// newest release overwrote the map entry), so the ~1,180 providers still
// running v0.8.15 failed their next attestation challenge ("provider runtime
// integrity mismatch in challenge response — excluding from routing", 1,184
// times) and the whole fleet was unroutable until every node self-updated on
// its 30-minute poll. The manifest is now the UNION of every ACTIVE release's
// hashes per template name, and only deactivating a release removes its values.
//
// The hashes echo the incident: 0.8.15 shipped metallib 08c48889…, 0.8.16
// shipped 4ffbbac4….
var (
	unionPreviousMetallib = strings.Repeat("08c48889", 8)
	unionNewestMetallib   = strings.Repeat("4ffbbac4", 8)
	unionUnknownMetallib  = strings.Repeat("d", 64)
)

// unionReleaseRow is a production-shape active release row (family template
// hashes, empty python/runtime hashes) carrying its own metallib hash.
func unionReleaseRow(version, binaryHash, metallib string) *store.Release {
	rel := productionShapeRelease(version, binaryHash)
	rel.MetallibHash = metallib
	return rel
}

// unionFleetProvider registers a routable mlx-swift provider whose last signed
// runtime identity reported the given metallib — a connected fleet node between
// challenges. Each provider serves its own model so routability is checked per
// provider.
func unionFleetProvider(t *testing.T, reg *registry.Registry, id, model, version, metallib string) *registry.Provider {
	t.Helper()
	provider := makeRoutableProvider(t, reg, id, model)
	provider.Mu().Lock()
	provider.Version = version
	provider.MetallibVerified = true
	provider.TemplateHashes = map[string]string{"mlx_metallib": metallib}
	provider.Mu().Unlock()
	return provider
}

// challengeWithMetallib drives the challenge-response runtime policy the way
// the attestation handler does (policy application, then capability
// reconciliation) and returns the policy verdict.
func challengeWithMetallib(t *testing.T, srv *Server, provider *registry.Provider, metallib string) (policyActive, runtimeOK bool) {
	t.Helper()
	resp := &protocol.AttestationResponseMessage{
		SIPEnabled: trBoolPtr(true), SecureBootEnabled: trBoolPtr(true),
		TemplateHashes: map[string]string{"mlx_metallib": metallib},
	}
	policyActive, runtimeOK, _ = srv.applyChallengeRuntimePolicy(provider, resp)
	_ = srv.registry.ReconcileAttestedRuntimeCapabilities(provider.ID)
	return policyActive, runtimeOK
}

// assertRuntimeApproved checks every manifest-derived routing gate plus actual
// routability for the provider's model.
func assertRuntimeApproved(t *testing.T, srv *Server, provider *registry.Provider, model string, want bool, when string) {
	t.Helper()
	provider.Mu().Lock()
	verified, checked, metallib := provider.RuntimeVerified, provider.RuntimeManifestChecked, provider.MetallibVerified
	provider.Mu().Unlock()
	if verified != want || checked != want || metallib != want {
		t.Fatalf("%s: %s runtime policy state = verified:%v checked:%v metallib:%v, want all %v",
			when, provider.ID, verified, checked, metallib, want)
	}
	routed := findRoutableProvider(srv.registry, model)
	switch {
	case want && (routed == nil || routed.ID != provider.ID):
		t.Fatalf("%s: %s must remain routable", when, provider.ID)
	case !want && routed != nil:
		t.Fatalf("%s: %s must be excluded from routing, but %s was routed", when, provider.ID, routed.ID)
	}
}

// TestRuntimeManifestAcceptsEveryActiveReleaseMetallib: with two active
// releases shipping different metallibs, a provider on EITHER passes the
// challenge runtime policy and stays routable, while a metallib no active
// release ships still fails closed.
func TestRuntimeManifestAcceptsEveryActiveReleaseMetallib(t *testing.T) {
	srv, st := runtimeManifestTestServer(t)
	for _, rel := range []*store.Release{
		unionReleaseRow("0.8.15", trHashA, unionPreviousMetallib),
		unionReleaseRow("0.8.16", trHashB, unionNewestMetallib),
	} {
		if err := st.SetRelease(rel); err != nil {
			t.Fatalf("SetRelease(%s): %v", rel.Version, err)
		}
	}
	if err := srv.SyncRuntimeManifest(); err != nil {
		t.Fatalf("SyncRuntimeManifest: %v", err)
	}
	accepted := srv.knownRuntimeManifest.TemplateHashes["mlx_metallib"]
	if len(accepted) != 2 || !accepted[unionPreviousMetallib] || !accepted[unionNewestMetallib] {
		t.Fatalf("mlx_metallib accepted set = %v, want both active releases' hashes", sortedTemplateHashes(accepted))
	}

	cases := []struct {
		name     string
		metallib string
		wantOK   bool
	}{
		{"provider still on the previous release", unionPreviousMetallib, true},
		{"provider already on the newest release", unionNewestMetallib, true},
		{"provider on a metallib no active release ships", unionUnknownMetallib, false},
	}
	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			model := fmt.Sprintf("union-metallib-model-%d", i)
			provider := unionFleetProvider(t, srv.registry, fmt.Sprintf("union-metallib-provider-%d", i), model, "0.8.15", tc.metallib)
			active, ok := challengeWithMetallib(t, srv, provider, tc.metallib)
			if !active {
				t.Fatal("runtime manifest policy must be active with two active releases")
			}
			if ok != tc.wantOK {
				t.Fatalf("challenge runtimeOK = %v, want %v", ok, tc.wantOK)
			}
			assertRuntimeApproved(t, srv, provider, model, tc.wantOK, "after challenge")
		})
	}
}

// TestRuntimeManifestDeactivationRemovesOnlyThatReleaseMetallib: pulling a
// release (the existing retirement mechanism) removes exactly its metallib from
// the union. Providers on that binary fail closed both at the live
// revalidation inside the sync and at their next challenge; providers on the
// remaining release keep routing.
func TestRuntimeManifestDeactivationRemovesOnlyThatReleaseMetallib(t *testing.T) {
	srv, st := runtimeManifestTestServer(t)
	for _, rel := range []*store.Release{
		unionReleaseRow("0.8.15", trHashA, unionPreviousMetallib),
		unionReleaseRow("0.8.16", trHashB, unionNewestMetallib),
	} {
		if err := st.SetRelease(rel); err != nil {
			t.Fatalf("SetRelease(%s): %v", rel.Version, err)
		}
	}
	if err := srv.SyncRuntimeManifest(); err != nil {
		t.Fatalf("SyncRuntimeManifest: %v", err)
	}

	const previousModel, newestModel = "deactivation-previous-model", "deactivation-newest-model"
	previous := unionFleetProvider(t, srv.registry, "deactivation-previous", previousModel, "0.8.15", unionPreviousMetallib)
	newest := unionFleetProvider(t, srv.registry, "deactivation-newest", newestModel, "0.8.16", unionNewestMetallib)
	if _, ok := challengeWithMetallib(t, srv, previous, unionPreviousMetallib); !ok {
		t.Fatal("previous-release provider must pass while its release is active")
	}
	if _, ok := challengeWithMetallib(t, srv, newest, unionNewestMetallib); !ok {
		t.Fatal("newest-release provider must pass while its release is active")
	}
	assertRuntimeApproved(t, srv, previous, previousModel, true, "before deactivation")
	assertRuntimeApproved(t, srv, newest, newestModel, true, "before deactivation")

	if err := st.DeleteRelease("0.8.15", defaultReleasePlatform); err != nil {
		t.Fatalf("DeleteRelease: %v", err)
	}
	if err := srv.SyncRuntimeManifest(); err != nil {
		t.Fatalf("SyncRuntimeManifest after deactivation: %v", err)
	}
	accepted := srv.knownRuntimeManifest.TemplateHashes["mlx_metallib"]
	if len(accepted) != 1 || !accepted[unionNewestMetallib] {
		t.Fatalf("mlx_metallib accepted set = %v, want only the remaining active release", sortedTemplateHashes(accepted))
	}

	// Live revalidation inside the sync deroutes the pulled release's fleet…
	assertRuntimeApproved(t, srv, previous, previousModel, false, "revalidation after deactivation")
	assertRuntimeApproved(t, srv, newest, newestModel, true, "revalidation after deactivation")
	// …and its next challenge fails closed too, while the survivor still passes.
	if _, ok := challengeWithMetallib(t, srv, previous, unionPreviousMetallib); ok {
		t.Fatal("deactivated release's metallib must fail the challenge runtime policy")
	}
	assertRuntimeApproved(t, srv, previous, previousModel, false, "challenge after deactivation")
	if _, ok := challengeWithMetallib(t, srv, newest, unionNewestMetallib); !ok {
		t.Fatal("remaining release's metallib must keep passing the challenge runtime policy")
	}
	assertRuntimeApproved(t, srv, newest, newestModel, true, "challenge after deactivation")
}

// TestRuntimeManifestUnionsPerFamilyTemplateHashes: the per-model-family
// template keys release rows carry (qwen3.5/trinity/gemma4/minimax) get the
// same union-and-membership semantics. NOTE: the challenge path
// (verifyRuntimeHashesForBackend) deliberately scopes verification to
// mlx_metallib — the family keys are CI fabrications no provider reports
// (2026-08-31 incident) — so this exercises the manifest and the generic set
// verifier directly.
func TestRuntimeManifestUnionsPerFamilyTemplateHashes(t *testing.T) {
	srv, st := runtimeManifestTestServer(t)
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
	manifest := srv.knownRuntimeManifest
	if got := manifest.TemplateHashes["qwen3.5"]; len(got) != 2 || !got[qwenOld] || !got[qwenNew] {
		t.Fatalf("qwen3.5 accepted set = %v, want both releases' values", sortedTemplateHashes(got))
	}
	if got := manifest.TemplateHashes["gemma4"]; len(got) != 1 || !got[gemmaShared] {
		t.Fatalf("gemma4 accepted set = %v, want the single shared value", sortedTemplateHashes(got))
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
			ok, mismatches := srv.verifyRuntimeHashesAgainstManifest(manifest, "", "", report(tc.qwen))
			if ok != tc.wantOK {
				t.Fatalf("verify = %v (%+v), want %v", ok, mismatches, tc.wantOK)
			}
			if !tc.wantOK && (len(mismatches) != 1 || mismatches[0].Component != "template:qwen3.5") {
				t.Fatalf("mismatches = %+v, want exactly one qwen3.5 mismatch", mismatches)
			}
		})
	}

	// Deactivating the older release removes only its value.
	if err := st.DeleteRelease("0.8.15", defaultReleasePlatform); err != nil {
		t.Fatalf("DeleteRelease: %v", err)
	}
	if err := srv.SyncRuntimeManifest(); err != nil {
		t.Fatalf("SyncRuntimeManifest after deactivation: %v", err)
	}
	manifest = srv.knownRuntimeManifest
	if got := manifest.TemplateHashes["qwen3.5"]; len(got) != 1 || !got[qwenNew] {
		t.Fatalf("qwen3.5 accepted set after deactivation = %v, want only the newer value", sortedTemplateHashes(got))
	}
	if ok, _ := srv.verifyRuntimeHashesAgainstManifest(manifest, "", "", report(qwenOld)); ok {
		t.Fatal("deactivated release's family template must no longer be accepted")
	}
	if ok, mismatches := srv.verifyRuntimeHashesAgainstManifest(manifest, "", "", report(qwenNew)); !ok {
		t.Fatalf("remaining release's family template must still be accepted: %+v", mismatches)
	}
}

// registerReleaseWithMetallibForTest registers a release through the real
// POST /v1/releases handler (artifact verification against the fake CDN
// included) with a caller-chosen metallib hash and production-shape family
// template hashes.
func registerReleaseWithMetallibForTest(
	t *testing.T, baseURL, cdnURL string, artifacts *releaseArtifactSet, version, metallib string,
) {
	t.Helper()
	bundle, binaryHash, bundleHash := buildReleaseBundleForTest(t, []byte("provider-"+version))
	path := "/releases/v" + version + "/darkbloom-bundle-macos-arm64.tar.gz"
	artifacts.mu.Lock()
	artifacts.bundles[path] = bundle
	artifacts.mu.Unlock()
	payload := map[string]string{
		"version": version, "platform": defaultReleasePlatform, "backend": "mlx-swift",
		"binary_hash": binaryHash, "bundle_hash": bundleHash,
		"metallib_hash": metallib, "url": cdnURL + path,
		"template_hashes": "qwen3.5=" + strings.Repeat("4", 64) + ",gemma4=" + strings.Repeat("6", 64),
		"changelog":       "release " + version,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(http.MethodPost, baseURL+"/v1/releases", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer release-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	responseBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("register %s: status=%d body=%s", version, resp.StatusCode, responseBody)
	}
}

// publishedMetallibHashes reads the public manifest endpoint's mlx_metallib
// list (sorted by the server).
func publishedMetallibHashes(t *testing.T, baseURL string) []string {
	t.Helper()
	body := getReleaseBody(t, baseURL+"/v1/runtime/manifest", http.StatusOK)
	var manifest struct {
		Configured     bool                `json:"configured"`
		TemplateHashes map[string][]string `json:"template_hashes"`
	}
	if err := json.Unmarshal(body, &manifest); err != nil {
		t.Fatalf("decode runtime manifest: %v (%s)", err, body)
	}
	if !manifest.Configured {
		t.Fatalf("runtime manifest not configured: %s", body)
	}
	return manifest.TemplateHashes["mlx_metallib"]
}

// TestRegisteringNewerReleaseKeepsPreviousReleaseFleetRuntimeVerified pins the
// 2026-09-03 incident end to end through the real POST /v1/releases handler:
// with the fleet connected on v0.8.15, registering v0.8.16 must leave every
// v0.8.15 provider runtime-verified — immediately (SyncRuntimeManifest's live
// revalidation) AND at its next attestation challenge — and routable, while a
// node that already self-updated passes too and an unknown metallib still
// fails closed. Only an explicit deactivation of v0.8.15 removes its metallib.
func TestRegisteringNewerReleaseKeepsPreviousReleaseFleetRuntimeVerified(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetReleaseKey("release-key")
	srv.adminKey = "admin-key"
	artifacts := &releaseArtifactSet{bundles: make(map[string][]byte)}
	cdn := httptest.NewServer(http.HandlerFunc(artifacts.handler))
	defer cdn.Close()
	srv.SetR2CDNURL(cdn.URL)
	apiServer := httptest.NewServer(srv.Handler())
	defer apiServer.Close()

	registerReleaseWithMetallibForTest(t, apiServer.URL, cdn.URL, artifacts, "0.8.15", unionPreviousMetallib)
	if got := publishedMetallibHashes(t, apiServer.URL); !reflect.DeepEqual(got, []string{unionPreviousMetallib}) {
		t.Fatalf("published mlx_metallib = %v, want only 0.8.15's", got)
	}

	// The connected fleet: every node registered and last challenged on 0.8.15.
	type fleetNode struct {
		provider *registry.Provider
		model    string
	}
	fleet := make([]fleetNode, 0, 3)
	for i := 0; i < 3; i++ {
		model := fmt.Sprintf("fleet-model-%d", i)
		provider := unionFleetProvider(t, srv.registry, fmt.Sprintf("fleet-node-%d", i), model, "0.8.15", unionPreviousMetallib)
		if _, ok := challengeWithMetallib(t, srv, provider, unionPreviousMetallib); !ok {
			t.Fatalf("%s must pass its challenge on the only active release", provider.ID)
		}
		assertRuntimeApproved(t, srv, provider, model, true, "before the newer release")
		fleet = append(fleet, fleetNode{provider, model})
	}

	// THE incident action: CI registers the next release while the fleet is live.
	registerReleaseWithMetallibForTest(t, apiServer.URL, cdn.URL, artifacts, "0.8.16", unionNewestMetallib)
	if got := publishedMetallibHashes(t, apiServer.URL); !reflect.DeepEqual(got, []string{unionPreviousMetallib, unionNewestMetallib}) {
		t.Fatalf("published mlx_metallib = %v, want the union of both active releases", got)
	}

	// Live revalidation inside the registration must not deroute anyone…
	for _, node := range fleet {
		assertRuntimeApproved(t, srv, node.provider, node.model, true, "immediately after registering the newer release")
	}
	// …and neither may the next challenge — the exact point where production
	// logged 1,184 runtime-integrity mismatches and lost the fleet.
	for _, node := range fleet {
		active, ok := challengeWithMetallib(t, srv, node.provider, unionPreviousMetallib)
		if !active || !ok {
			t.Fatalf("%s on the previous release failed its post-registration challenge (active=%v ok=%v)",
				node.provider.ID, active, ok)
		}
		assertRuntimeApproved(t, srv, node.provider, node.model, true, "challenge after registering the newer release")
	}

	// A node that already self-updated passes with the new metallib.
	updated := unionFleetProvider(t, srv.registry, "fleet-node-updated", "fleet-model-updated", "0.8.16", unionNewestMetallib)
	if _, ok := challengeWithMetallib(t, srv, updated, unionNewestMetallib); !ok {
		t.Fatal("provider on the newly registered release must pass its challenge")
	}
	assertRuntimeApproved(t, srv, updated, "fleet-model-updated", true, "updated node")

	// Fail-closed is intact: a metallib no active release ships still fails.
	rogue := unionFleetProvider(t, srv.registry, "fleet-node-rogue", "fleet-model-rogue", "0.8.16", unionUnknownMetallib)
	if _, ok := challengeWithMetallib(t, srv, rogue, unionUnknownMetallib); ok {
		t.Fatal("unknown metallib must fail the challenge runtime policy")
	}
	assertRuntimeApproved(t, srv, rogue, "fleet-model-rogue", false, "rogue node")

	// Retiring the previous release is an explicit operator action, not a side
	// effect of registering the next one.
	deactivateReleaseForCacheTest(t, apiServer.URL, "0.8.15", defaultReleasePlatform)
	if got := publishedMetallibHashes(t, apiServer.URL); !reflect.DeepEqual(got, []string{unionNewestMetallib}) {
		t.Fatalf("published mlx_metallib after deactivation = %v, want only 0.8.16's", got)
	}
	for _, node := range fleet {
		assertRuntimeApproved(t, srv, node.provider, node.model, false, "after 0.8.15 was deactivated")
	}
	assertRuntimeApproved(t, srv, updated, "fleet-model-updated", true, "after 0.8.15 was deactivated")
}
