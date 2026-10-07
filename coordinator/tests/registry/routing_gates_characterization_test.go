package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Keep the distinct dispatch, alias, warm, public and load-planning decisions.
// These intentional differences are not interchangeable routing verdicts.
type gateOutcomes struct {
	routingGates       bool
	routingGatesSelf   bool
	routingGatesBypass bool
	canRoutePublic     bool
	canRouteRelaxed    bool
	hasWarm            bool
	publiclyRoutable   bool
	warmReason         warmplan.ColdReason
	modelLoadCand      bool
}

type gateCharacterizationRegistry struct {
	*production.Registry
	eligibility *production.ReservationPlanner
	loads       *production.ModelLoadPlanner
}

func newGateCharacterizationRegistry(dependencies ...production.Dependencies) *gateCharacterizationRegistry {
	f := &gateCharacterizationRegistry{}
	var deps production.Dependencies
	if len(dependencies) > 0 {
		deps = dependencies[0]
	}
	reservations, loads := deps.Reservations, deps.ModelLoadPlanning
	deps.Reservations = func(actual *production.ReservationPlanner) production.ReservationPreparation {
		f.eligibility = actual
		if reservations != nil {
			return reservations(actual)
		}
		return actual
	}
	deps.ModelLoadPlanning = func(actual *production.ModelLoadPlanner) production.ModelLoadPlanning {
		f.loads = actual
		if loads != nil {
			return loads(actual)
		}
		return actual
	}
	f.Registry = production.NewWithDependencies(testLogger(), deps)
	return f
}

func collectGateOutcomes(reg *gateCharacterizationRegistry, p *production.Provider, model string, now time.Time) gateOutcomes {
	var out gateOutcomes
	eligibility := reg.eligibility.PrepareEligibility()
	out.routingGates, _ = eligibility.Routing(p.ID, model, production.RequestTraits{}, false, now, false, false)
	out.routingGatesSelf, _ = eligibility.Routing(p.ID, model, production.RequestTraits{}, true, now, false, false)
	out.routingGatesBypass, _ = eligibility.Routing(p.ID, model, production.RequestTraits{}, false, now, true, false)
	out.canRoutePublic = eligibility.Build(p.ID, model, reg.MinTrustLevel, now, false, false)
	out.canRouteRelaxed = eligibility.Build(p.ID, model, production.TrustNone, now, true, false)
	out.publiclyRoutable = eligibility.Public(p.ID, now)
	eligibility.Close()

	// Sequential leases avoid recursive RLock when a writer is waiting. These
	// characterization fixtures do not mutate providers between the operations.
	loads := reg.loads.Prepare()
	defer loads.Close()
	out.hasWarm = loads.Warm(p.ID, model, now)
	_, out.warmReason = loads.ColdCandidate(p.ID, model, now)
	_, out.modelLoadCand = loads.Candidate(p.ID, model, now)
	return out
}

const gateCharModel = "gate-char-model"

func baselineGateProvider(t *testing.T, reg *gateCharacterizationRegistry, mutate func(*production.Provider)) *production.Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg.Registry, "gate-char", gateCharModel, 80)
	if mutate != nil {
		p.Mu().Lock()
		mutate(p)
		p.Mu().Unlock()
	}
	return p
}

func TestRoutingGateCharacterization(t *testing.T) {
	now := time.Now()
	cases := []struct {
		name  string
		build func(*testing.T, *gateCharacterizationRegistry) (*production.Provider, string)
		want  gateOutcomes
	}{
		{
			name: "baseline_routable_warm_idle",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				return baselineGateProvider(t, reg, nil), gateCharModel
			},
			want: gateOutcomes{
				routingGates: true, routingGatesSelf: true, routingGatesBypass: true,
				canRoutePublic: true, canRouteRelaxed: true,
				hasWarm: true, publiclyRoutable: true,
				warmReason: warmplan.WarmColdEligible, modelLoadCand: true,
			},
		},
		{
			name: "status_offline",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				return baselineGateProvider(t, reg, func(p *production.Provider) { p.Status = production.StatusOffline }), gateCharModel
			},
			want: gateOutcomes{warmReason: warmplan.WarmColdOfflineUntrust},
		},
		{
			name: "status_untrusted",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				return baselineGateProvider(t, reg, func(p *production.Provider) { p.Status = production.StatusUntrusted }), gateCharModel
			},
			want: gateOutcomes{warmReason: warmplan.WarmColdOfflineUntrust},
		},
		{
			name: "private_only",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				return baselineGateProvider(t, reg, func(p *production.Provider) { p.PrivateOnly = true }), gateCharModel
			},
			want: gateOutcomes{
				routingGatesSelf: true, canRouteRelaxed: true,
				warmReason: warmplan.WarmColdOfflineUntrust,
			},
		},
		{
			name: "trust_below_floor",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				return baselineGateProvider(t, reg, func(p *production.Provider) { p.TrustLevel = production.TrustSelfSigned }), gateCharModel
			},
			want: gateOutcomes{
				routingGatesSelf: true, canRouteRelaxed: true,
				warmReason: warmplan.WarmColdTrust,
			},
		},
		{
			name: "runtime_unverified",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				return baselineGateProvider(t, reg, func(p *production.Provider) { p.RuntimeVerified = false }), gateCharModel
			},
			want: gateOutcomes{warmReason: warmplan.WarmColdTrust},
		},
		{
			name: "private_text_unsupported",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				return baselineGateProvider(t, reg, func(p *production.Provider) { p.ChallengeVerifiedSIP = false }), gateCharModel
			},
			want: gateOutcomes{warmReason: warmplan.WarmColdTrust},
		},
		{
			name: "stale_challenge",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				return baselineGateProvider(t, reg, func(p *production.Provider) { p.LastChallengeVerified = time.Time{} }), gateCharModel
			},
			want: gateOutcomes{warmReason: warmplan.WarmColdStaleChallenge},
		},
		{
			name: "unadvertised_model_catalog_miss",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				return baselineGateProvider(t, reg, nil), "model-this-provider-does-not-serve"
			},
			want: gateOutcomes{publiclyRoutable: true, warmReason: warmplan.WarmColdNotServing},
		},
		{
			name: "dedicated_excluded_mixed_box",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				p := makeSchedulerProvider(t, reg.Registry, "mixed", gemmaBuild, 80)
				reg.MergeProviderModels(p.ID, []protocol.ModelInfo{{ID: qwenBuild, ModelType: "chat", Quantization: "4bit"}})
				reg.SetDedicatedModels([]string{"gemma-4"})
				return p, gemmaBuild
			},
			want: gateOutcomes{
				routingGatesSelf: true, canRouteRelaxed: true,
				publiclyRoutable: true, warmReason: warmplan.WarmColdDedicated,
			},
		},
		{
			name: "cold_slot_unknown_not_loaded",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				return baselineGateProvider(t, reg, func(p *production.Provider) {
					p.BackendCapacity.Slots[0].State = "unknown"
				}), gateCharModel
			},
			want: gateOutcomes{
				routingGates: true, routingGatesSelf: true, routingGatesBypass: true,
				canRoutePublic: true, canRouteRelaxed: true,
				hasWarm: false, publiclyRoutable: true,
				warmReason: warmplan.WarmColdEligible, modelLoadCand: true,
			},
		},
		{
			name: "slot_crashed",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				return baselineGateProvider(t, reg, func(p *production.Provider) {
					p.BackendCapacity.Slots[0].State = "crashed"
				}), gateCharModel
			},
			want: gateOutcomes{
				routingGates: true, routingGatesSelf: true, routingGatesBypass: true,
				canRoutePublic: false, canRouteRelaxed: false,
				hasWarm: false, publiclyRoutable: true,
				warmReason: warmplan.WarmColdEligible, modelLoadCand: true,
			},
		},
		{
			name: "warm_pool_not_idle",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				return baselineGateProvider(t, reg, func(p *production.Provider) {
					p.BackendCapacity.Slots[0].NumRunning = 1
				}), gateCharModel
			},
			want: gateOutcomes{
				routingGates: true, routingGatesSelf: true, routingGatesBypass: true,
				canRoutePublic: true, canRouteRelaxed: true,
				hasWarm: true, publiclyRoutable: true,
				warmReason: warmplan.WarmColdNotIdle, modelLoadCand: true,
			},
		},
		{
			name: "node_breaker_open",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				p := baselineGateProvider(t, reg, nil)
				for i := 0; i < identitygate.ProviderBreakerConsecTrip; i++ {
					reg.RecordProviderOutcome(p.ID, false, 500, "")
				}
				return p, gateCharModel
			},
			want: gateOutcomes{
				routingGates: false, routingGatesSelf: false, routingGatesBypass: true,
				canRoutePublic: true, canRouteRelaxed: true,
				hasWarm: true, publiclyRoutable: true,
				warmReason: warmplan.WarmColdEligible, modelLoadCand: true,
			},
		},
		{
			name: "render_broken_template",
			build: func(t *testing.T, reg *gateCharacterizationRegistry) (*production.Provider, string) {
				return baselineGateProvider(t, reg, func(p *production.Provider) {
					broken := false
					p.Models[0].TemplateRenderOK = &broken
				}), gateCharModel
			},
			want: gateOutcomes{
				routingGates: false, routingGatesSelf: false, routingGatesBypass: false,
				canRoutePublic: true, canRouteRelaxed: true,
				hasWarm: true, publiclyRoutable: true,
				warmReason: warmplan.WarmColdEligible, modelLoadCand: true,
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := newGateCharacterizationRegistry()
			p, model := tc.build(t, reg)
			got := collectGateOutcomes(reg, p, model, now)
			if got != tc.want {
				t.Fatalf("gate outcomes mismatch:\n got  %+v\n want %+v", got, tc.want)
			}
		})
	}
}

func TestRoutingGateDispatchCooldown(t *testing.T) {
	now := time.Now()
	reg := newGateCharacterizationRegistry()
	p := baselineGateProvider(t, reg, nil)
	if got := collectGateOutcomes(reg, p, gateCharModel, now); !got.routingGates || !got.canRoutePublic || got.warmReason != warmplan.WarmColdEligible {
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
	if got.warmReason != warmplan.WarmColdPendingLoad {
		t.Errorf("warm pool must report pending_load_or_cooldown, got %q", got.warmReason)
	}
	if !got.hasWarm {
		t.Error("warm detection must ignore the dispatch-load cooldown")
	}
	if !got.publiclyRoutable {
		t.Error("public-routable must ignore the dispatch-load cooldown")
	}
}

func TestRoutingGateInferenceErrorCooldown(t *testing.T) {
	now := time.Now()
	reg := newGateCharacterizationRegistry()
	p := baselineGateProvider(t, reg, nil)
	traits := production.RequestTraits{}
	shape := traits.CooldownShape()
	for i := 0; i < 2; i++ {
		reg.RecordInferenceError(p.ID, gateCharModel, 500, shape)
	}
	eligibility := reg.eligibility.PrepareEligibility()
	dispatch, _ := eligibility.Routing(p.ID, gateCharModel, traits, false, now, false, false)
	canRoute := eligibility.Build(p.ID, gateCharModel, reg.MinTrustLevel, now, false, false)
	eligibility.Close()
	loads := reg.loads.Prepare()
	hasWarm := loads.Warm(p.ID, gateCharModel, now)
	loads.Close()
	if dispatch {
		t.Error("dispatch gate must skip a triple in inference-error cooldown")
	}
	if !canRoute {
		t.Error("alias routability must ignore the inference-error cooldown")
	}
	if !hasWarm {
		t.Error("warm detection must ignore the inference-error cooldown")
	}
}

func newGateEvidenceRegistry(enforced bool) *gateCharacterizationRegistry {
	reg := newGateCharacterizationRegistry()
	reg.MinTrustLevel = production.TrustNone
	reg.SetReleasePolicyGeneration(1, true, nil)
	reg.SetReleasePolicyEnforcement(enforced)
	return reg
}

func evidenceGateTestProvider(reg *gateCharacterizationRegistry, id string) *production.Provider {
	p := reg.Register(id, nil, &protocol.RegisterMessage{
		Backend: production.BackendMLXSwift, APNsDeviceToken: "token",
		EncryptedResponseChunks: true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true, TextProxyDisabled: true,
			AntiDebugEnabled: true, CoreDumpsDisabled: true, EnvScrubbed: true,
		},
	})
	p.Mu().Lock()
	defer p.Mu().Unlock()
	// These policy fixtures deliberately retain the original synthetic identity
	// and old version; they exercise evidence binding, not registration validation.
	p.PublicKey = "process-key"
	p.Version = "0.8.15"
	p.Status = ""
	p.RuntimeVerified = false
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.CodeAttested = true
	p.AttestationResult = &attestation.VerificationResult{Valid: true, PublicKey: "se-key", SerialNumber: "SERIAL"}
	return p
}

func (reg *gateCharacterizationRegistry) supportsPrivateText(provider *production.Provider) bool {
	eligibility := reg.eligibility.PrepareEligibility()
	defer eligibility.Close()
	return eligibility.PrivateText(provider.ID, time.Now())
}

func TestReleasePolicyGenerationImmediatelyDeroutesStaleApplicationEvidence(t *testing.T) {
	reg := newGateEvidenceRegistry(true)
	provider := evidenceGateTestProvider(reg, "provider")
	provider.ApplicationEvidence = production.ApplicationEvidence{
		SEPublicKey: "se-key", Serial: "SERIAL",
		ProcessPublicKey: "process-key", APNsToken: "token",
		BinaryHash: "hash", Version: "0.8.15", Backend: production.BackendMLXSwift,
		EvidenceGeneration: 1, PolicyGeneration: 1,
	}
	if !reg.supportsPrivateText(provider) {
		t.Fatal("current release evidence should authorize the routing contribution")
	}
	if invalidated := reg.SetReleasePolicyGeneration(2, true, nil); len(invalidated) != 1 || invalidated[0] != provider.ID {
		t.Fatalf("policy refresh must report the deverified provider for immediate re-challenge, got %v", invalidated)
	}
	if reg.supportsPrivateText(provider) {
		t.Fatal("policy refresh retained stale release-derived routing authority")
	}
	if _, ok := provider.ApplicationEvidenceSnapshot(); ok {
		t.Fatal("policy refresh did not synchronously clear application evidence")
	}
	if !provider.GetCodeAttested() {
		t.Fatal("policy refresh destroyed independent genuine APNs proof")
	}
}

func TestReleasePolicyGenerationCarriesForwardStillApprovedEvidence(t *testing.T) {
	reg := newGateEvidenceRegistry(true)
	provider := evidenceGateTestProvider(reg, "provider")
	provider.ApplicationEvidence = production.ApplicationEvidence{
		SEPublicKey: "se-key", Serial: "SERIAL",
		ProcessPublicKey: "process-key", APNsToken: "token",
		BinaryHash: "hash", Version: "0.8.15", Backend: production.BackendMLXSwift,
		EvidenceGeneration: 1, PolicyGeneration: 1,
	}
	invalidated := reg.SetReleasePolicyGeneration(2, true,
		func(evidence production.ApplicationEvidence) bool { return evidence.BinaryHash == "hash" })
	if len(invalidated) != 0 {
		t.Fatalf("still-approved evidence must not be invalidated, got %v", invalidated)
	}
	evidence, ok := provider.ApplicationEvidenceSnapshot()
	if !ok || evidence.PolicyGeneration != 2 {
		t.Fatalf("carried-forward evidence not re-stamped at new generation: %+v ok=%v", evidence, ok)
	}
	if !reg.supportsPrivateText(provider) {
		t.Fatal("still-approved provider must remain routable across the policy refresh")
	}
	invalidated = reg.SetReleasePolicyGeneration(3, true,
		func(evidence production.ApplicationEvidence) bool { return false })
	if len(invalidated) != 1 || invalidated[0] != provider.ID {
		t.Fatalf("no-longer-approved evidence must be invalidated + reported, got %v", invalidated)
	}
	if reg.supportsPrivateText(provider) {
		t.Fatal("invalidated provider must not remain routable")
	}
}

func TestReleasePolicyShadowModeNeverBlocksRouting(t *testing.T) {
	reg := newGateEvidenceRegistry(false)
	provider := evidenceGateTestProvider(reg, "provider")
	if !reg.supportsPrivateText(provider) {
		t.Fatal("shadow mode must route a provider without application evidence")
	}
	holding, connected := reg.CountProvidersWithCurrentApplicationEvidence()
	if holding != 0 || connected != 1 {
		t.Fatalf("shadow coverage counter = (%d, %d), want (0, 1)", holding, connected)
	}
	reg.SetReleasePolicyEnforcement(true)
	if reg.supportsPrivateText(provider) {
		t.Fatal("enforce mode must deroute a provider without application evidence")
	}
	provider.ApplicationEvidence = production.ApplicationEvidence{
		SEPublicKey: "se-key", Serial: "SERIAL",
		ProcessPublicKey: "process-key", APNsToken: "token",
		BinaryHash: "hash", Version: "0.8.15", Backend: production.BackendMLXSwift,
		EvidenceGeneration: 1, PolicyGeneration: 1,
	}
	if !reg.supportsPrivateText(provider) {
		t.Fatal("enforce mode must route once current evidence is held")
	}
	holding, connected = reg.CountProvidersWithCurrentApplicationEvidence()
	if holding != 1 || connected != 1 {
		t.Fatalf("coverage counter after grant = (%d, %d), want (1, 1)", holding, connected)
	}
}

func TestReleasePolicyEnforceAfterDelaysEnforcement(t *testing.T) {
	reg := newGateEvidenceRegistry(false)
	provider := evidenceGateTestProvider(reg, "provider")
	reg.SetReleasePolicyEnforcement(true)
	reg.SetReleasePolicyEnforceAfter(time.Now().Add(time.Hour))
	if reg.ReleasePolicyEnforced() {
		t.Fatal("enforcement must not be live during the boot grace")
	}
	if !reg.supportsPrivateText(provider) {
		t.Fatal("boot grace must route an evidence-less provider like shadow mode")
	}
	reg.SetReleasePolicyEnforceAfter(time.Now().Add(-time.Second))
	if !reg.ReleasePolicyEnforced() {
		t.Fatal("enforcement must go live once the boot grace elapses")
	}
	if reg.supportsPrivateText(provider) {
		t.Fatal("elapsed grace must enforce the evidence gate")
	}
}

func TestReleasePolicySweepKeepsCapabilitiesInShadow(t *testing.T) {
	reg := newGateEvidenceRegistry(false)
	provider := evidenceGateTestProvider(reg, "provider")
	provider.RuntimeCapabilities = []string{production.ProviderCapabilityMLXNAX}
	if reg.SetReleasePolicyGeneration(2, true, nil); provider.RuntimeCapabilities == nil {
		t.Fatal("shadow sweep must not clear runtime capabilities")
	}
	reg.SetReleasePolicyEnforcement(true)
	if reg.SetReleasePolicyGeneration(3, true, nil); provider.RuntimeCapabilities != nil {
		t.Fatal("enforced sweep must clear runtime capabilities with the evidence")
	}
}

func TestApplicationEvidenceModelCoverage(t *testing.T) {
	reg := newGateEvidenceRegistry(false)
	covered := evidenceGateTestProvider(reg, "covered")
	covered.Status = production.StatusOnline
	covered.RuntimeVerified = true
	covered.LastChallengeVerified = time.Now()
	reg.MergeProviderModels(covered.ID, []protocol.ModelInfo{{ID: "model-covered"}})
	covered.ApplicationEvidence = production.ApplicationEvidence{
		SEPublicKey: "se-key", Serial: "SERIAL",
		ProcessPublicKey: "process-key", APNsToken: "token",
		BinaryHash: "hash", Version: "0.8.15", Backend: production.BackendMLXSwift,
		EvidenceGeneration: 1, PolicyGeneration: 1,
	}
	uncovered := evidenceGateTestProvider(reg, "uncovered")
	uncovered.PublicKey = "process-key-2"
	uncovered.AttestationResult = &attestation.VerificationResult{
		Valid: true, PublicKey: "se-key-2", SerialNumber: "SERIAL-2",
	}
	uncovered.Status = production.StatusOnline
	uncovered.RuntimeVerified = true
	uncovered.LastChallengeVerified = time.Now()
	reg.MergeProviderModels(uncovered.ID, []protocol.ModelInfo{{ID: "model-uncovered"}})
	coverage := reg.ApplicationEvidenceModelCoverage()
	if c := coverage["model-covered"]; c.Routable != 1 || c.WithEvidence != 1 {
		t.Fatalf("covered model coverage = %+v, want {1 1}", c)
	}
	if c := coverage["model-uncovered"]; c.Routable != 1 || c.WithEvidence != 0 {
		t.Fatalf("uncovered model coverage = %+v, want {1 0}", c)
	}
}
