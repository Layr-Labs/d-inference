package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// This file is a behavior-locking characterization suite for the five
// overlapping provider-eligibility gate functions:
//
//   - providerPassesRoutingGatesLockedEx (scheduler.go) — dispatch hot path
//   - providerCanRouteBuildLocked        (registry.go)  — alias routability
//   - providerHasWarmModelLocked         (registry.go)  — warm detection
//   - publiclyRoutableLocked             (registry.go)  — capacity feeds
//   - warmPoolCandidateReasonLocked      (warm_pool_controller.go) — warming
//
// plus modelLoadCandidatePendingLocked (registry.go), which shares the same
// liveness/trust/privacy core and is also folded onto the shared helper.
//
// These tests pin the EXACT current decision of every gate across a matrix of
// provider states, INCLUDING the intentional differences between them (the
// owner self-route relaxation, the breaker-ignoring preflight bypass, the
// warm-only loaded check, the catalog-only / model-agnostic checks, and the
// granular warm-pool reason labels). They must stay green before AND after the
// routing-gate pipeline unification — that is the proof the refactor is exactly
// behavior-preserving. Do NOT relax an expectation to make a refactor pass; a
// changed value here is a real behavior change.

// gateOutcomes is the full decision tuple of every gate function for one
// (registry, provider, model) state.
type gateOutcomes struct {
	routingGates       bool // providerPassesRoutingGatesLockedEx(selfRouteOwner=false, ignoreBreaker=false)
	routingGatesSelf   bool // ...(selfRouteOwner=true,  ignoreBreaker=false)
	routingGatesBypass bool // ...(selfRouteOwner=false, ignoreBreaker=true)
	canRoutePublic     bool // providerCanRouteBuildLocked(minTrust=MinTrustLevel, allowPrivate=false)
	canRouteRelaxed    bool // providerCanRouteBuildLocked(minTrust=TrustNone,     allowPrivate=true)
	hasWarm            bool // providerHasWarmModelLocked
	publiclyRoutable   bool // publiclyRoutableLocked (model-agnostic)
	warmReason         warmColdReason
	modelLoadCand      bool // modelLoadCandidatePendingLocked ok
}

// collectGateOutcomes evaluates every gate function under the correct lock
// discipline. modelLoadCandidatePendingLocked takes p.mu itself, so it is
// called after releasing the provider lock.
func collectGateOutcomes(reg *Registry, p *Provider, model string, now time.Time) gateOutcomes {
	reg.mu.RLock()
	defer reg.mu.RUnlock()

	var out gateOutcomes
	p.mu.Lock()
	out.routingGates = reg.providerPassesRoutingGatesLockedEx(p, model, RequestTraits{}, false, now, false, false)
	out.routingGatesSelf = reg.providerPassesRoutingGatesLockedEx(p, model, RequestTraits{}, true, now, false, false)
	out.routingGatesBypass = reg.providerPassesRoutingGatesLockedEx(p, model, RequestTraits{}, false, now, true, false)
	out.canRoutePublic = reg.providerCanRouteBuildLocked(p, model, reg.MinTrustLevel, now, false)
	out.canRouteRelaxed = reg.providerCanRouteBuildLocked(p, model, TrustNone, now, true)
	out.hasWarm = reg.providerHasWarmModelLocked(p, model, now)
	out.publiclyRoutable = reg.publiclyRoutableLocked(p, now)
	_, out.warmReason = reg.warmPoolCandidateReasonLocked(p, model, now)
	p.mu.Unlock()

	_, out.modelLoadCand = reg.modelLoadCandidatePendingLocked(p, model, now)
	return out
}

const gateCharModel = "gate-char-model"

// baselineGateProvider builds a fully routable, warm, idle provider for
// gateCharModel and applies the optional mutation.
func baselineGateProvider(t *testing.T, reg *Registry, mutate func(p *Provider)) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, "gate-char", gateCharModel, 80)
	if mutate != nil {
		p.mu.Lock()
		mutate(p)
		p.mu.Unlock()
	}
	return p
}

func TestRoutingGateCharacterization(t *testing.T) {
	now := time.Now()

	cases := []struct {
		name  string
		build func(t *testing.T, reg *Registry) (p *Provider, model string)
		want  gateOutcomes
	}{
		{
			name: "baseline_routable_warm_idle",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				return baselineGateProvider(t, reg, nil), gateCharModel
			},
			want: gateOutcomes{
				routingGates: true, routingGatesSelf: true, routingGatesBypass: true,
				canRoutePublic: true, canRouteRelaxed: true,
				hasWarm: true, publiclyRoutable: true,
				warmReason: warmColdEligible, modelLoadCand: true,
			},
		},
		{
			name: "status_offline",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				return baselineGateProvider(t, reg, func(p *Provider) { p.Status = StatusOffline }), gateCharModel
			},
			want: gateOutcomes{warmReason: warmColdOfflineUntrust},
		},
		{
			name: "status_untrusted",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				return baselineGateProvider(t, reg, func(p *Provider) { p.Status = StatusUntrusted }), gateCharModel
			},
			want: gateOutcomes{warmReason: warmColdOfflineUntrust},
		},
		{
			name: "private_only",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				return baselineGateProvider(t, reg, func(p *Provider) { p.PrivateOnly = true }), gateCharModel
			},
			// Relaxed (owner self-route) admits a private-only box; public paths reject it.
			want: gateOutcomes{
				routingGatesSelf: true, canRouteRelaxed: true,
				warmReason: warmColdOfflineUntrust,
			},
		},
		{
			name: "trust_below_floor",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				return baselineGateProvider(t, reg, func(p *Provider) { p.TrustLevel = TrustSelfSigned }), gateCharModel
			},
			// Relaxed paths drop the trust floor to TrustNone.
			want: gateOutcomes{
				routingGatesSelf: true, canRouteRelaxed: true,
				warmReason: warmColdTrust,
			},
		},
		{
			name: "runtime_unverified",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				return baselineGateProvider(t, reg, func(p *Provider) { p.RuntimeVerified = false }), gateCharModel
			},
			// Runtime verification is a privacy-critical gate — never relaxed.
			want: gateOutcomes{warmReason: warmColdTrust},
		},
		{
			name: "private_text_unsupported",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				return baselineGateProvider(t, reg, func(p *Provider) { p.ChallengeVerifiedSIP = false }), gateCharModel
			},
			want: gateOutcomes{warmReason: warmColdTrust},
		},
		{
			name: "stale_challenge",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				return baselineGateProvider(t, reg, func(p *Provider) { p.LastChallengeVerified = time.Time{} }), gateCharModel
			},
			want: gateOutcomes{warmReason: warmColdStaleChallenge},
		},
		{
			name: "unadvertised_model_catalog_miss",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				// publiclyRoutableLocked is model-agnostic, so it still passes.
				return baselineGateProvider(t, reg, nil), "model-this-provider-does-not-serve"
			},
			want: gateOutcomes{
				publiclyRoutable: true,
				warmReason:       warmColdNotServing,
			},
		},
		{
			name: "dedicated_excluded_mixed_box",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				p := makeSchedulerProvider(t, reg, "mixed", gemmaBuild, 80)
				addAdvertisedModel(p, qwenBuild) // mixed catalog → not dedicated to gemma-4
				reg.SetDedicatedModels([]string{"gemma-4"})
				return p, gemmaBuild
			},
			// Dedicated rule is exempted only on the owner self-route relaxation;
			// publiclyRoutableLocked ignores the model entirely.
			want: gateOutcomes{
				routingGatesSelf: true, canRouteRelaxed: true,
				publiclyRoutable: true,
				warmReason:       warmColdDedicated,
			},
		},
		{
			name: "cold_slot_unknown_not_loaded",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				return baselineGateProvider(t, reg, func(p *Provider) {
					p.BackendCapacity.Slots[0].State = "unknown"
				}), gateCharModel
			},
			// Only providerHasWarmModelLocked requires the model to be loaded;
			// every routability gate treats a cold-but-healthy box as eligible,
			// and the warm pool WANTS to warm an idle cold box.
			want: gateOutcomes{
				routingGates: true, routingGatesSelf: true, routingGatesBypass: true,
				canRoutePublic: true, canRouteRelaxed: true,
				hasWarm: false, publiclyRoutable: true,
				warmReason: warmColdEligible, modelLoadCand: true,
			},
		},
		{
			name: "slot_crashed",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				return baselineGateProvider(t, reg, func(p *Provider) {
					p.BackendCapacity.Slots[0].State = "crashed"
				}), gateCharModel
			},
			// Only providerCanRouteBuildLocked applies the slot-state gate; the
			// dispatch path defers it to buildCandidateWithReason, so routingGates
			// still passes here.
			want: gateOutcomes{
				routingGates: true, routingGatesSelf: true, routingGatesBypass: true,
				canRoutePublic: false, canRouteRelaxed: false,
				hasWarm: false, publiclyRoutable: true,
				warmReason: warmColdEligible, modelLoadCand: true,
			},
		},
		{
			name: "warm_pool_not_idle",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				return baselineGateProvider(t, reg, func(p *Provider) {
					p.BackendCapacity.Slots[0].NumRunning = 1
				}), gateCharModel
			},
			// A busy backend slot only disqualifies the warm pool (it picks idle
			// boxes); every other gate is unaffected and the slot is still warm.
			want: gateOutcomes{
				routingGates: true, routingGatesSelf: true, routingGatesBypass: true,
				canRoutePublic: true, canRouteRelaxed: true,
				hasWarm: true, publiclyRoutable: true,
				warmReason: warmColdNotIdle, modelLoadCand: true,
			},
		},
		{
			name: "node_breaker_open",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				p := baselineGateProvider(t, reg, nil)
				for i := 0; i < providerBreakerConsecTrip; i++ {
					reg.RecordProviderOutcome(p.ID, false, 500, "")
				}
				return p, gateCharModel
			},
			// The node-health breaker lives ONLY in the dispatch gate and is
			// bypassable by the fail-open pass; no other gate consults it.
			want: gateOutcomes{
				routingGates: false, routingGatesSelf: false, routingGatesBypass: true,
				canRoutePublic: true, canRouteRelaxed: true,
				hasWarm: true, publiclyRoutable: true,
				warmReason: warmColdEligible, modelLoadCand: true,
			},
		},
		{
			name: "render_broken_template",
			build: func(t *testing.T, reg *Registry) (*Provider, string) {
				return baselineGateProvider(t, reg, func(p *Provider) {
					broken := false
					p.Models[0].TemplateRenderOK = &broken
				}), gateCharModel
			},
			// The trait/render-broken gate lives ONLY in the dispatch gate and
			// fences every request shape; it is never relaxed.
			want: gateOutcomes{
				routingGates: false, routingGatesSelf: false, routingGatesBypass: false,
				canRoutePublic: true, canRouteRelaxed: true,
				hasWarm: true, publiclyRoutable: true,
				warmReason: warmColdEligible, modelLoadCand: true,
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := New(testLogger())
			p, model := tc.build(t, reg)
			got := collectGateOutcomes(reg, p, model, now)
			if got != tc.want {
				t.Fatalf("gate outcomes mismatch:\n got  %+v\n want %+v", got, tc.want)
			}
		})
	}
}

// TestRoutingGateDispatchCooldown locks the dispatch-load cooldown gate, which
// is shared by the dispatch path, alias routability, and the warm pool — but
// NOT by warm-detection, public-routable, or the load planner's liveness core.
func TestRoutingGateDispatchCooldown(t *testing.T) {
	now := time.Now()
	reg := New(testLogger())
	p := baselineGateProvider(t, reg, nil)

	// Sanity: clean baseline routes everywhere.
	if got := collectGateOutcomes(reg, p, gateCharModel, now); !got.routingGates || !got.canRoutePublic || got.warmReason != warmColdEligible {
		t.Fatalf("baseline must route before cooldown: %+v", got)
	}

	reg.RecordDispatchLoadFailure(p.ID, gateCharModel)

	got := collectGateOutcomes(reg, p, gateCharModel, now)
	if got.routingGates {
		t.Error("dispatch path must skip a provider in dispatch-load cooldown")
	}
	if got.canRoutePublic || got.canRouteRelaxed {
		t.Error("alias routability must skip a provider in dispatch-load cooldown")
	}
	if got.warmReason != warmColdPendingLoad {
		t.Errorf("warm pool must report pending_load_or_cooldown, got %q", got.warmReason)
	}
	// Warm detection, public-routable, and the load planner do NOT consult the
	// dispatch-load cooldown.
	if !got.hasWarm {
		t.Error("warm detection must ignore the dispatch-load cooldown")
	}
	if !got.publiclyRoutable {
		t.Error("public-routable must ignore the dispatch-load cooldown")
	}
}

// TestRoutingGateInferenceErrorCooldown locks the shape-keyed inference-error
// cooldown gate, which lives ONLY in the dispatch gate.
func TestRoutingGateInferenceErrorCooldown(t *testing.T) {
	now := time.Now()
	reg := New(testLogger())
	p := baselineGateProvider(t, reg, nil)

	traits := RequestTraits{}
	shape := traits.CooldownShape()
	for i := 0; i < inferenceErrorThreshold; i++ {
		reg.RecordInferenceError(p.ID, gateCharModel, 500, shape)
	}

	reg.mu.RLock()
	p.mu.Lock()
	dispatch := reg.providerPassesRoutingGatesLockedEx(p, gateCharModel, traits, false, now, false, false)
	canRoute := reg.providerCanRouteBuildLocked(p, gateCharModel, reg.MinTrustLevel, now, false)
	hasWarm := reg.providerHasWarmModelLocked(p, gateCharModel, now)
	p.mu.Unlock()
	reg.mu.RUnlock()

	if dispatch {
		t.Error("dispatch gate must skip a triple in inference-error cooldown")
	}
	// The inference-error cooldown is dispatch-only: alias routability and warm
	// detection must NOT consult it.
	if !canRoute {
		t.Error("alias routability must ignore the inference-error cooldown")
	}
	if !hasWarm {
		t.Error("warm detection must ignore the inference-error cooldown")
	}
}

// TestReleasePolicyGenerationImmediatelyDeroutesStaleApplicationEvidence
// characterizes ENFORCE mode: with enforcement on, a policy refresh that
// invalidates evidence must synchronously remove routing authority.
func TestReleasePolicyGenerationImmediatelyDeroutesStaleApplicationEvidence(t *testing.T) {
	reg := &Registry{
		providers:               make(map[string]*Provider),
		releasePolicyGeneration: 1,
		releasePolicyRequired:   true,
		releasePolicyEnforced:   true,
	}
	provider := &Provider{
		ID: "provider", PublicKey: "process-key", Backend: BackendMLXSwift,
		Version: "0.8.15", APNsDeviceToken: "token",
		EncryptedResponseChunks: true,
		RuntimeManifestChecked:  true, ChallengeVerifiedSIP: true,
		CodeAttested: true,
		AttestationResult: &attestation.VerificationResult{
			Valid: true, PublicKey: "se-key", SerialNumber: "SERIAL",
		},
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true,
			TextProxyDisabled:    true,
			AntiDebugEnabled:     true,
			CoreDumpsDisabled:    true,
			EnvScrubbed:          true,
		},
		ApplicationEvidence: ApplicationEvidence{
			SEPublicKey: "se-key", Serial: "SERIAL",
			ProcessPublicKey: "process-key", APNsToken: "token",
			BinaryHash: "hash", Version: "0.8.15", Backend: BackendMLXSwift,
			EvidenceGeneration: 1, PolicyGeneration: 1,
		},
	}
	insertTestProvider(reg, provider)
	if !reg.providerSupportsPrivateTextLocked(provider) {
		t.Fatal("current release evidence should authorize the routing contribution")
	}

	if invalidated := reg.SetReleasePolicyGeneration(2, true, nil); len(invalidated) != 1 || invalidated[0] != provider.ID {
		t.Fatalf("policy refresh must report the deverified provider for immediate re-challenge, got %v", invalidated)
	}
	if reg.providerSupportsPrivateTextLocked(provider) {
		t.Fatal("policy refresh retained stale release-derived routing authority")
	}
	if _, ok := provider.ApplicationEvidenceSnapshot(); ok {
		t.Fatal("policy refresh did not synchronously clear application evidence")
	}
	if !provider.GetCodeAttested() {
		t.Fatal("policy refresh destroyed independent genuine APNs proof")
	}
}

// TestReleasePolicyGenerationCarriesForwardStillApprovedEvidence is the
// upgrade-storm regression at the registry layer: a policy refresh whose
// predicate vouches for the existing evidence (same approved hash) must NOT
// clear it — the evidence is re-stamped at the new generation and the provider
// stays routable with no re-challenge round-trip.
func TestReleasePolicyGenerationCarriesForwardStillApprovedEvidence(t *testing.T) {
	reg := &Registry{
		providers:               make(map[string]*Provider),
		releasePolicyGeneration: 1,
		releasePolicyRequired:   true,
		releasePolicyEnforced:   true,
	}
	provider := &Provider{
		ID: "provider", PublicKey: "process-key", Backend: BackendMLXSwift,
		Version: "0.8.15", APNsDeviceToken: "token",
		EncryptedResponseChunks: true,
		RuntimeManifestChecked:  true, ChallengeVerifiedSIP: true,
		CodeAttested: true,
		AttestationResult: &attestation.VerificationResult{
			Valid: true, PublicKey: "se-key", SerialNumber: "SERIAL",
		},
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true,
			TextProxyDisabled:    true,
			AntiDebugEnabled:     true,
			CoreDumpsDisabled:    true,
			EnvScrubbed:          true,
		},
		ApplicationEvidence: ApplicationEvidence{
			SEPublicKey: "se-key", Serial: "SERIAL",
			ProcessPublicKey: "process-key", APNsToken: "token",
			BinaryHash: "hash", Version: "0.8.15", Backend: BackendMLXSwift,
			EvidenceGeneration: 1, PolicyGeneration: 1,
		},
	}
	insertTestProvider(reg, provider)

	invalidated := reg.SetReleasePolicyGeneration(2, true,
		func(evidence ApplicationEvidence) bool { return evidence.BinaryHash == "hash" })
	if len(invalidated) != 0 {
		t.Fatalf("still-approved evidence must not be invalidated, got %v", invalidated)
	}
	evidence, ok := provider.ApplicationEvidenceSnapshot()
	if !ok || evidence.PolicyGeneration != 2 {
		t.Fatalf("carried-forward evidence not re-stamped at new generation: %+v ok=%v", evidence, ok)
	}
	if !reg.providerSupportsPrivateTextLocked(provider) {
		t.Fatal("still-approved provider must remain routable across the policy refresh")
	}

	// The same refresh with a predicate that rejects the hash clears + reports it.
	invalidated = reg.SetReleasePolicyGeneration(3, true,
		func(evidence ApplicationEvidence) bool { return false })
	if len(invalidated) != 1 || invalidated[0] != provider.ID {
		t.Fatalf("no-longer-approved evidence must be invalidated + reported, got %v", invalidated)
	}
	if reg.providerSupportsPrivateTextLocked(provider) {
		t.Fatal("invalidated provider must not remain routable")
	}
}

// TestReleasePolicyShadowModeNeverBlocksRouting pins the rollout contract that
// prevented a third zero-capacity deploy: with a required release policy but
// enforcement OFF (the default), a provider with NO application evidence —
// exactly the state of the whole production fleet the moment a new coordinator
// boots — keeps routing, while the same provider is derouted the instant
// enforcement flips on, and re-admitted once evidence lands.
func TestReleasePolicyShadowModeNeverBlocksRouting(t *testing.T) {
	reg := &Registry{
		providers:               make(map[string]*Provider),
		releasePolicyGeneration: 1,
		releasePolicyRequired:   true,
	}
	provider := &Provider{
		ID: "provider", PublicKey: "process-key", Backend: BackendMLXSwift,
		Version: "0.8.15", APNsDeviceToken: "token",
		EncryptedResponseChunks: true,
		RuntimeManifestChecked:  true, ChallengeVerifiedSIP: true,
		CodeAttested: true,
		AttestationResult: &attestation.VerificationResult{
			Valid: true, PublicKey: "se-key", SerialNumber: "SERIAL",
		},
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true,
			TextProxyDisabled:    true,
			AntiDebugEnabled:     true,
			CoreDumpsDisabled:    true,
			EnvScrubbed:          true,
		},
	}
	insertTestProvider(reg, provider)

	if !reg.providerSupportsPrivateTextLocked(provider) {
		t.Fatal("shadow mode must route a provider without application evidence")
	}
	holding, connected := reg.CountProvidersWithCurrentApplicationEvidence()
	if holding != 0 || connected != 1 {
		t.Fatalf("shadow coverage counter = (%d, %d), want (0, 1)", holding, connected)
	}

	reg.SetReleasePolicyEnforcement(true)
	if reg.providerSupportsPrivateTextLocked(provider) {
		t.Fatal("enforce mode must deroute a provider without application evidence")
	}

	provider.ApplicationEvidence = ApplicationEvidence{
		SEPublicKey: "se-key", Serial: "SERIAL",
		ProcessPublicKey: "process-key", APNsToken: "token",
		BinaryHash: "hash", Version: "0.8.15", Backend: BackendMLXSwift,
		EvidenceGeneration: 1, PolicyGeneration: 1,
	}
	if !reg.providerSupportsPrivateTextLocked(provider) {
		t.Fatal("enforce mode must route once current evidence is held")
	}
	holding, connected = reg.CountProvidersWithCurrentApplicationEvidence()
	if holding != 1 || connected != 1 {
		t.Fatalf("coverage counter after grant = (%d, %d), want (1, 1)", holding, connected)
	}
}

// evidenceGateTestProvider builds the minimal provider that passes every
// routing-chokepoint gate except application evidence.
func evidenceGateTestProvider() *Provider {
	return &Provider{
		ID: "provider", PublicKey: "process-key", Backend: BackendMLXSwift,
		Version: "0.8.15", APNsDeviceToken: "token",
		EncryptedResponseChunks: true,
		RuntimeManifestChecked:  true, ChallengeVerifiedSIP: true,
		CodeAttested: true,
		AttestationResult: &attestation.VerificationResult{
			Valid: true, PublicKey: "se-key", SerialNumber: "SERIAL",
		},
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true,
			TextProxyDisabled:    true,
			AntiDebugEnabled:     true,
			CoreDumpsDisabled:    true,
			EnvScrubbed:          true,
		},
	}
}

// TestReleasePolicyEnforceAfterDelaysEnforcement pins the restart-into-enforce
// contract: a coordinator that boots with enforcement configured has an empty
// registry (zero evidence), so the enforce-after boot grace must keep routing
// shadow-like until it elapses — otherwise the flip procedure itself recreates
// the zero-capacity transient it exists to prevent.
func TestReleasePolicyEnforceAfterDelaysEnforcement(t *testing.T) {
	reg := &Registry{
		providers:               make(map[string]*Provider),
		releasePolicyGeneration: 1,
		releasePolicyRequired:   true,
	}
	provider := evidenceGateTestProvider()
	insertTestProvider(reg, provider)

	reg.SetReleasePolicyEnforcement(true)
	reg.SetReleasePolicyEnforceAfter(time.Now().Add(time.Hour))
	if reg.ReleasePolicyEnforced() {
		t.Fatal("enforcement must not be live during the boot grace")
	}
	if !reg.providerSupportsPrivateTextLocked(provider) {
		t.Fatal("boot grace must route an evidence-less provider like shadow mode")
	}

	reg.SetReleasePolicyEnforceAfter(time.Now().Add(-time.Second))
	if !reg.ReleasePolicyEnforced() {
		t.Fatal("enforcement must go live once the boot grace elapses")
	}
	if reg.providerSupportsPrivateTextLocked(provider) {
		t.Fatal("elapsed grace must enforce the evidence gate")
	}
}

// TestReleasePolicySweepKeepsCapabilitiesInShadow pins the shadow no-touch
// contract for capability routing: a policy sweep that wipes underivable
// evidence must NOT clear RuntimeCapabilities in shadow mode (capability
// bookkeeping would silently remove capability-gated model capacity), while
// the same sweep under live enforcement must clear them.
func TestReleasePolicySweepKeepsCapabilitiesInShadow(t *testing.T) {
	reg := &Registry{
		providers:               make(map[string]*Provider),
		releasePolicyGeneration: 1,
		releasePolicyRequired:   true,
	}
	provider := evidenceGateTestProvider()
	provider.RuntimeCapabilities = []string{ProviderCapabilityMLXNAX}
	insertTestProvider(reg, provider)

	if reg.SetReleasePolicyGeneration(2, true, nil); provider.RuntimeCapabilities == nil {
		t.Fatal("shadow sweep must not clear runtime capabilities")
	}

	reg.SetReleasePolicyEnforcement(true)
	if reg.SetReleasePolicyGeneration(3, true, nil); provider.RuntimeCapabilities != nil {
		t.Fatal("enforced sweep must clear runtime capabilities with the evidence")
	}
}

// TestApplicationEvidenceModelCoverage pins the per-model flip criterion: the
// coverage map must expose an uncovered model family even when another model's
// providers are fully covered, so a fleet-wide average cannot hide it.
func TestApplicationEvidenceModelCoverage(t *testing.T) {
	reg := &Registry{
		providers:               make(map[string]*Provider),
		releasePolicyGeneration: 1,
		releasePolicyRequired:   true,
	}
	covered := evidenceGateTestProvider()
	covered.ID = "covered"
	covered.Status = StatusOnline
	covered.RuntimeVerified = true
	covered.LastChallengeVerified = time.Now()
	covered.Models = []protocol.ModelInfo{{ID: "model-covered"}}
	covered.ApplicationEvidence = ApplicationEvidence{
		SEPublicKey: "se-key", Serial: "SERIAL",
		ProcessPublicKey: "process-key", APNsToken: "token",
		BinaryHash: "hash", Version: "0.8.15", Backend: BackendMLXSwift,
		EvidenceGeneration: 1, PolicyGeneration: 1,
	}
	uncovered := evidenceGateTestProvider()
	uncovered.ID = "uncovered"
	uncovered.PublicKey = "process-key-2"
	uncovered.AttestationResult = &attestation.VerificationResult{
		Valid: true, PublicKey: "se-key-2", SerialNumber: "SERIAL-2",
	}
	uncovered.Status = StatusOnline
	uncovered.RuntimeVerified = true
	uncovered.LastChallengeVerified = time.Now()
	uncovered.Models = []protocol.ModelInfo{{ID: "model-uncovered"}}
	insertTestProvider(reg, covered)
	insertTestProvider(reg, uncovered)

	coverage := reg.ApplicationEvidenceModelCoverage()
	if c := coverage["model-covered"]; c.Routable != 1 || c.WithEvidence != 1 {
		t.Fatalf("covered model coverage = %+v, want {1 1}", c)
	}
	if c := coverage["model-uncovered"]; c.Routable != 1 || c.WithEvidence != 0 {
		t.Fatalf("uncovered model coverage = %+v, want {1 0}", c)
	}
}
