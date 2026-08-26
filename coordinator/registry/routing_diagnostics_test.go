package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// The whole point of routing_diagnostics.go is that the reason a machine is
// fenced and the decision to fence it are the SAME code. These tests hold that
// line: the first suite proves the boolean predicates and the blocker
// functions cannot disagree under any single-gate mutation, and the second
// proves the reported verdict matches what `ListModels` / `OwnedModels`
// actually did.

// routableProvider registers a provider that passes every gate.
func routableProvider(t *testing.T, r *Registry, id, model string) *Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	p := r.Register(id, nil, msg)
	p.mu.Lock()
	p.AccountID = "acct-1"
	p.TrustLevel = TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.mu.Unlock()
	return p
}

// gateMutation breaks exactly one gate on an otherwise-routable provider.
// `arm` handles gates that live on registry policy rather than provider state.
type gateMutation struct {
	name    string
	apply   func(p *Provider)
	blocker RoutingBlocker
	arm     func(r *Registry)
}

func singleGateMutations() []gateMutation {
	return []gateMutation{
		{"none", func(p *Provider) {}, "", nil},
		{"offline", func(p *Provider) { p.Status = StatusOffline }, BlockerOffline, nil},
		{"untrusted", func(p *Provider) { p.Status = StatusUntrusted }, BlockerUntrusted, nil},
		{"private_only", func(p *Provider) { p.PrivateOnly = true }, BlockerPrivateOnly, nil},
		{"trust_none", func(p *Provider) { p.TrustLevel = TrustNone }, BlockerTrustBelowMinimum, nil},
		{"runtime_unverified", func(p *Provider) { p.RuntimeVerified = false }, BlockerRuntimeUnverified, nil},
		{"no_public_key", func(p *Provider) { p.PublicKey = "" }, BlockerNoEncryptionKey, nil},
		{"bad_backend", func(p *Provider) { p.Backend = "python-mlx" }, BlockerUnsupportedBackend, nil},
		{"plaintext_chunks", func(p *Provider) { p.EncryptedResponseChunks = false }, BlockerUnencryptedChunks, nil},
		{"manifest_unchecked", func(p *Provider) { p.RuntimeManifestChecked = false }, BlockerRuntimeManifestUnchecked, nil},
		{"sip_unverified", func(p *Provider) { p.ChallengeVerifiedSIP = false }, BlockerSIPUnverified, nil},
		{"caps_missing", func(p *Provider) { p.PrivacyCapabilities = nil }, BlockerPrivacyCapsMissing, nil},
		{"caps_incomplete", func(p *Provider) { p.PrivacyCapabilities.AntiDebugEnabled = false }, BlockerPrivacyCapsIncomplete, nil},
		{"challenge_never", func(p *Provider) { p.LastChallengeVerified = time.Time{} }, BlockerChallengeNever, nil},
		{"challenge_stale", func(p *Provider) {
			p.LastChallengeVerified = time.Now().Add(-ChallengeFreshnessMaxAge - time.Minute)
		}, BlockerChallengeStale, nil},
		{
			name:    "code_attestation_missing",
			apply:   func(p *Provider) { p.CodeAttested = false },
			blocker: BlockerCodeAttestationMissing,
			arm: func(r *Registry) {
				r.SetCodeAttestationPolicy(true, time.Now().Add(-time.Hour))
			},
		},
		{
			// `trustRank` returns -1 for an unrecognised level, which a
			// restored store row can carry verbatim.
			name:    "unrecognised_trust",
			apply:   func(p *Provider) { p.TrustLevel = TrustLevel("bogus") },
			blocker: BlockerTrustBelowMinimum,
		},
	}
}

func TestLivenessBlockerMatchesLivenessGate(t *testing.T) {
	for _, mutation := range singleGateMutations() {
		t.Run(mutation.name, func(t *testing.T) {
			r := New(testLogger())
			r.MinTrustLevel = TrustHardware
			p := routableProvider(t, r, "p1", gemmaBuild)
			if mutation.arm != nil {
				mutation.arm(r)
			}

			p.mu.Lock()
			mutation.apply(p)
			p.mu.Unlock()

			now := time.Now()
			r.mu.RLock()
			p.mu.Lock()
			blocker := r.providerLivenessBlockerLocked(p, r.MinTrustLevel, false, now)
			gate := r.providerLivenessGateLocked(p, r.MinTrustLevel, false, now)
			p.mu.Unlock()
			r.mu.RUnlock()

			if blocker != mutation.blocker {
				t.Fatalf("blocker = %q, want %q", blocker, mutation.blocker)
			}
			// The invariant that makes the diagnostic trustworthy.
			if gate != (blocker == "") {
				t.Fatalf("gate = %v but blocker = %q — the diagnostic and the router disagree", gate, blocker)
			}
		})
	}
}

func TestPrivateTextBlockerMatchesPrivateTextPredicate(t *testing.T) {
	for _, mutation := range singleGateMutations() {
		t.Run(mutation.name, func(t *testing.T) {
			r := New(testLogger())
			r.MinTrustLevel = TrustHardware
			p := routableProvider(t, r, "p1", gemmaBuild)
			if mutation.arm != nil {
				mutation.arm(r)
			}

			p.mu.Lock()
			mutation.apply(p)
			p.mu.Unlock()

			r.mu.RLock()
			p.mu.Lock()
			blocker := r.providerPrivateTextBlockerLocked(p)
			supported := r.providerSupportsPrivateTextLocked(p)
			p.mu.Unlock()
			r.mu.RUnlock()

			if supported != (blocker == "") {
				t.Fatalf("providerSupportsPrivateTextLocked = %v but blocker = %q", supported, blocker)
			}
			// Which gate refused, not just that one did. Without this the
			// suite would pass if two gates were transposed.
			if privateTextBlockers[mutation.blocker] && blocker != mutation.blocker {
				t.Fatalf("blocker = %q, want %q", blocker, mutation.blocker)
			}
			if !privateTextBlockers[mutation.blocker] && blocker != "" {
				t.Fatalf("blocker = %q, want the private-text gate to pass", blocker)
			}
		})
	}
}

// The subset of gates the private-text chokepoint owns. Anything else in the
// mutation matrix is checked by an earlier or later gate, so the chokepoint
// must report clean for it.
var privateTextBlockers = map[RoutingBlocker]bool{
	BlockerNoEncryptionKey:          true,
	BlockerUnsupportedBackend:       true,
	BlockerUnencryptedChunks:        true,
	BlockerRuntimeManifestUnchecked: true,
	BlockerSIPUnverified:            true,
	BlockerCodeAttestationMissing:   true,
	BlockerPrivacyCapsMissing:       true,
	BlockerPrivacyCapsIncomplete:    true,
}

// TestAdvertisingMatchesListModels is the assertion an operator actually cares
// about: whatever the diagnostic says must be what the coordinator did. It
// pins BOTH verdicts against their real implementations — `Advertising`
// against `ListModels`, `Routable` against the production reservation path —
// so a future edit to either gate that forgets the diagnostic fails here.
func TestAdvertisingMatchesListModels(t *testing.T) {
	for _, mutation := range singleGateMutations() {
		t.Run(mutation.name, func(t *testing.T) {
			r := New(testLogger())
			r.MinTrustLevel = TrustHardware
			p := routableProvider(t, r, "p1", gemmaBuild)
			if mutation.arm != nil {
				mutation.arm(r)
			}

			p.mu.Lock()
			mutation.apply(p)
			p.mu.Unlock()

			listed := false
			for _, m := range r.ListModels() {
				if m.ID == gemmaBuild && m.Providers > 0 {
					listed = true
				}
			}
			diag := r.RoutingDiagnostics("p1", time.Now())
			if diag == nil {
				t.Fatal("RoutingDiagnostics returned nil for a connected provider")
			}
			if diag.Advertising != listed {
				t.Fatalf("Advertising = %v but ListModels listed = %v (blockers %v)",
					diag.Advertising, listed, diag.Blockers)
			}
			// Routable is the strictly stronger claim.
			if diag.Routable && !diag.Advertising {
				t.Fatalf("Routable without Advertising (blockers %v)", diag.Blockers)
			}
			// BOTH directions against the production reservation path. The
			// one-sided version of this assertion is what let an
			// over-optimistic verdict ship: `Routable` must not claim more
			// than dispatch delivers, and must not claim less either.
			reserved := findRoutableProvider(r, gemmaBuild) != nil
			if diag.Routable != reserved {
				t.Fatalf("Routable = %v but ReserveProviderEx selected = %v (blockers %v)",
					diag.Routable, reserved, diag.Blockers)
			}
			if mutation.name == "none" && !reserved {
				t.Fatal("a fully-healthy provider must be reservable")
			}
			if !diag.Routable && len(diag.Blockers) == 0 {
				t.Fatal("unroutable provider reported no reason")
			}
			if diag.Routable && len(diag.Blockers) != 0 {
				t.Fatalf("routable provider reported blockers %v", diag.Blockers)
			}
		})
	}
}

func TestOwnerRoutableMatchesOwnedModels(t *testing.T) {
	for _, mutation := range singleGateMutations() {
		t.Run(mutation.name, func(t *testing.T) {
			r := New(testLogger())
			r.MinTrustLevel = TrustHardware
			p := routableProvider(t, r, "p1", gemmaBuild)
			if mutation.arm != nil {
				mutation.arm(r)
			}

			p.mu.Lock()
			mutation.apply(p)
			p.mu.Unlock()

			owned := false
			for _, m := range r.OwnedModels("acct-1") {
				if m.ID == gemmaBuild {
					owned = true
				}
			}
			diag := r.RoutingDiagnostics("p1", time.Now())
			if diag.OwnerRoutable != owned {
				t.Fatalf("OwnerRoutable = %v but OwnedModels listed = %v (blockers %v)",
					diag.OwnerRoutable, owned, diag.Blockers)
			}
		})
	}
}

// A machine that passes every machine-level gate but registered nothing is the
// exact "green dashboard, empty catalog" shape operators report.
func TestNoModelsRegisteredIsReported(t *testing.T) {
	r := New(testLogger())
	r.MinTrustLevel = TrustHardware
	p := routableProvider(t, r, "p1", gemmaBuild)
	p.mu.Lock()
	p.Models = nil
	p.mu.Unlock()

	diag := r.RoutingDiagnostics("p1", time.Now())
	if diag.Advertising || diag.Routable {
		t.Fatal("a provider with no models must not report as advertising or routable")
	}
	if len(diag.Blockers) != 1 || diag.Blockers[0] != BlockerNoModelsRegistered {
		t.Fatalf("blockers = %v, want [%s]", diag.Blockers, BlockerNoModelsRegistered)
	}
}

// The asymmetry that makes this whole file necessary: the public catalog does
// NOT apply the runtime-hash or challenge-freshness gates, so a fenced machine
// still shows up in /v1/models. Reporting only "advertising" would tell that
// operator everything is fine.
func TestAdvertisingCanBeTrueWhileUnroutable(t *testing.T) {
	for _, tc := range []struct {
		name    string
		apply   func(p *Provider)
		blocker RoutingBlocker
	}{
		{"runtime unverified", func(p *Provider) { p.RuntimeVerified = false }, BlockerRuntimeUnverified},
		{"challenge stale", func(p *Provider) {
			p.LastChallengeVerified = time.Now().Add(-ChallengeFreshnessMaxAge - time.Minute)
		}, BlockerChallengeStale},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := New(testLogger())
			r.MinTrustLevel = TrustHardware
			p := routableProvider(t, r, "p1", gemmaBuild)
			p.mu.Lock()
			tc.apply(p)
			p.mu.Unlock()

			diag := r.RoutingDiagnostics("p1", time.Now())
			if !diag.Advertising {
				t.Fatal("expected the machine to still be counted in the public catalog")
			}
			if diag.Routable {
				t.Fatal("expected the machine to be unroutable")
			}
			if len(diag.Blockers) != 1 || diag.Blockers[0] != tc.blocker {
				t.Fatalf("blockers = %v, want [%s]", diag.Blockers, tc.blocker)
			}
			if findRoutableProvider(r, gemmaBuild) != nil {
				t.Fatal("the production reservation path selected a fenced provider")
			}
		})
	}
}

func TestModelBlockersReportCatalogExclusions(t *testing.T) {
	r := New(testLogger())
	r.MinTrustLevel = TrustHardware
	p := routableProvider(t, r, "p1", gemmaBuild)

	renderBroken := false
	p.mu.Lock()
	p.Models = []protocol.ModelInfo{
		{ID: gemmaBuild, WeightHash: "goodhash"},
		{ID: qwenBuild, WeightHash: "wronghash"},
		{ID: gemmaBuildSmol, WeightHash: "smolhash", TemplateRenderOK: &renderBroken},
		{ID: "some-unpublished-build"},
	}
	p.mu.Unlock()
	r.SetModelCatalog([]CatalogEntry{
		{ID: gemmaBuild, WeightHash: "goodhash"},
		{ID: qwenBuild, WeightHash: "righthash"},
		{ID: gemmaBuildSmol, WeightHash: "smolhash"},
	})

	diag := r.RoutingDiagnostics("p1", time.Now())
	byID := make(map[string]ModelRoutingDiagnostics, len(diag.Models))
	for _, m := range diag.Models {
		byID[m.ID] = m
	}

	if got := byID[gemmaBuild]; !got.PubliclyListed || !got.OwnerRoutable || len(got.Blockers) != 0 {
		t.Fatalf("healthy build reported %+v", got)
	}
	if got := byID[qwenBuild]; got.PubliclyListed ||
		len(got.Blockers) != 1 || got.Blockers[0] != BlockerModelWeightHashMismatch {
		t.Fatalf("stale-hash build reported %+v", got)
	}
	if got := byID[gemmaBuildSmol]; got.OwnerRoutable ||
		len(got.Blockers) != 1 || got.Blockers[0] != BlockerModelTemplateRenderBroken {
		t.Fatalf("render-broken build reported %+v", got)
	}
	if got := byID["some-unpublished-build"]; got.PubliclyListed ||
		len(got.Blockers) != 1 || got.Blockers[0] != BlockerModelNotInCatalog {
		t.Fatalf("off-catalog build reported %+v", got)
	}
	// The machine still advertises, because one build survived.
	if !diag.Advertising {
		t.Fatalf("machine with one healthy build must advertise (blockers %v)", diag.Blockers)
	}
}

// Every model excluded is a distinct shape from no models at all: the machine
// registered inventory, so the reason lives on the per-model rows.
func TestEveryModelExcludedReportsNoRoutableModels(t *testing.T) {
	r := New(testLogger())
	r.MinTrustLevel = TrustHardware
	p := routableProvider(t, r, "p1", gemmaBuild)
	p.mu.Lock()
	p.Models = []protocol.ModelInfo{{ID: "unpublished-a"}, {ID: "unpublished-b"}}
	p.mu.Unlock()
	r.SetModelCatalog([]CatalogEntry{{ID: gemmaBuild}})

	diag := r.RoutingDiagnostics("p1", time.Now())
	if diag.Advertising || diag.Routable {
		t.Fatal("no catalog-allowed build must not advertise or be routable")
	}
	if len(diag.Blockers) != 1 || diag.Blockers[0] != BlockerNoRoutableModels {
		t.Fatalf("blockers = %v, want [%s]", diag.Blockers, BlockerNoRoutableModels)
	}
	if len(diag.Models) != 2 {
		t.Fatalf("expected per-model rows for both builds, got %d", len(diag.Models))
	}
}

// A render-broken build is fenced for EVERY request shape at dispatch
// (`providerEligibleForTraitsLocked`) while still being counted in the public
// catalog. Reporting it as routable would be the exact lie this file exists to
// prevent.
func TestRenderBrokenOnlyMachineIsNotRoutable(t *testing.T) {
	r := New(testLogger())
	r.MinTrustLevel = TrustHardware
	p := routableProvider(t, r, "p1", gemmaBuild)
	renderBroken := false
	p.mu.Lock()
	p.Models = []protocol.ModelInfo{{ID: gemmaBuild, TemplateRenderOK: &renderBroken}}
	p.mu.Unlock()

	diag := r.RoutingDiagnostics("p1", time.Now())
	if !diag.Advertising {
		t.Fatal("the public catalog does apply the render gate, so it should still list")
	}
	if diag.Routable {
		t.Fatalf("a render-broken-only machine must not report routable (%+v)", diag.Models)
	}
	if findRoutableProvider(r, gemmaBuild) != nil {
		t.Fatal("the production reservation path selected a render-broken build")
	}
	if len(diag.Models) != 1 || diag.Models[0].Routable {
		t.Fatalf("model row = %+v", diag.Models)
	}
}

// Dedicated-box isolation is enabled by default in production for the gemma-4
// family, so a mixed box gets no gemma-4 traffic. It has to say so.
func TestDedicatedRuleExclusionIsReported(t *testing.T) {
	r := New(testLogger())
	r.MinTrustLevel = TrustHardware
	r.SetDedicatedModels([]string{"gemma-4"})
	p := routableProvider(t, r, "p1", gemmaBuild)
	p.mu.Lock()
	p.Models = []protocol.ModelInfo{{ID: gemmaBuild}, {ID: qwenBuild}}
	p.mu.Unlock()

	diag := r.RoutingDiagnostics("p1", time.Now())
	byID := make(map[string]ModelRoutingDiagnostics, len(diag.Models))
	for _, m := range diag.Models {
		byID[m.ID] = m
	}
	gemma := byID[gemmaBuild]
	if gemma.Routable {
		t.Fatalf("a mixed box must not report the dedicated build as routable: %+v", gemma)
	}
	found := false
	for _, b := range gemma.Blockers {
		if b == BlockerModelDedicatedBoxOnly {
			found = true
		}
	}
	if !found {
		t.Fatalf("blockers = %v, want to contain %s", gemma.Blockers, BlockerModelDedicatedBoxOnly)
	}
	if findRoutableProvider(r, gemmaBuild) != nil {
		t.Fatal("the production reservation path selected a non-dedicated box")
	}
	// The non-dedicated build on the same box is unaffected.
	if !byID[qwenBuild].Routable {
		t.Fatalf("the non-dedicated build must still route: %+v", byID[qwenBuild])
	}
	if !diag.Routable {
		t.Fatal("a machine with one routable build is routable")
	}
}

// An empty catalog and a machine-level fence are separate facts with separate
// remedies; reporting only the first one sends the operator back to square one
// after they fix it.
func TestEmptyCatalogIsReportedAlongsideADispatchBlocker(t *testing.T) {
	r := New(testLogger())
	r.MinTrustLevel = TrustHardware
	p := routableProvider(t, r, "p1", gemmaBuild)
	p.mu.Lock()
	p.RuntimeVerified = false
	p.Models = []protocol.ModelInfo{{ID: "unpublished"}}
	p.mu.Unlock()
	r.SetModelCatalog([]CatalogEntry{{ID: gemmaBuild}})

	diag := r.RoutingDiagnostics("p1", time.Now())
	var sawRuntime, sawEmpty bool
	for _, b := range diag.Blockers {
		sawRuntime = sawRuntime || b == BlockerRuntimeUnverified
		sawEmpty = sawEmpty || b == BlockerNoRoutableModels
	}
	if !sawRuntime || !sawEmpty {
		t.Fatalf("blockers = %v, want both the runtime fence and the empty catalog", diag.Blockers)
	}
}

func TestRoutingDiagnosticsUnknownProvider(t *testing.T) {
	r := New(testLogger())
	if diag := r.RoutingDiagnostics("nope", time.Now()); diag != nil {
		t.Fatalf("expected nil for an unknown provider, got %+v", diag)
	}
}

func TestEveryBlockerHasRemediationText(t *testing.T) {
	all := []RoutingBlocker{
		BlockerOffline, BlockerUntrusted, BlockerPrivateOnly, BlockerTrustBelowMinimum,
		BlockerRuntimeUnverified, BlockerChallengeNever, BlockerChallengeStale,
		BlockerNoEncryptionKey, BlockerUnsupportedBackend, BlockerUnencryptedChunks,
		BlockerRuntimeManifestUnchecked, BlockerSIPUnverified, BlockerCodeAttestationMissing,
		BlockerPrivacyCapsMissing, BlockerPrivacyCapsIncomplete,
		BlockerNoModelsRegistered, BlockerNoRoutableModels,
		BlockerModelNotInCatalog, BlockerModelWeightHashMismatch,
		BlockerModelTemplateRenderBroken, BlockerModelDedicatedBoxOnly,
	}
	for _, b := range all {
		if got := b.Description(); got == "" || got == string(b) {
			t.Fatalf("blocker %q has no operator-facing description", b)
		}
	}
}

func TestChallengeFreshnessWindowIsReported(t *testing.T) {
	r := New(testLogger())
	r.MinTrustLevel = TrustHardware
	routableProvider(t, r, "p1", gemmaBuild)
	diag := r.RoutingDiagnostics("p1", time.Now())
	if diag.ChallengeMaxAgeSeconds != int(ChallengeFreshnessMaxAge.Seconds()) {
		t.Fatalf("ChallengeMaxAgeSeconds = %d, want %d",
			diag.ChallengeMaxAgeSeconds, int(ChallengeFreshnessMaxAge.Seconds()))
	}
}
