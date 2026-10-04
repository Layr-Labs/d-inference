package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestRegisterAndGetProvider(t *testing.T) {
	reg := production.New(testLogger())
	msg := testRegisterMessage()

	p := reg.Register("p1", nil, msg)

	if p.ID != "p1" {
		t.Errorf("id = %q, want %q", p.ID, "p1")
	}
	if p.Status != production.StatusOnline {
		t.Errorf("status = %q, want %q", p.Status, production.StatusOnline)
	}
	if len(p.Models) != 1 {
		t.Errorf("models = %d, want 1", len(p.Models))
	}

	got := reg.GetProvider("p1")
	if got == nil {
		t.Fatal("GetProvider returned nil")
	}
	if got.ID != "p1" {
		t.Errorf("got id = %q", got.ID)
	}

	if reg.ProviderCount() != 1 {
		t.Errorf("count = %d, want 1", reg.ProviderCount())
	}
}

func TestProviderMissingPrivacyCapsExcludedFromTextRouting(t *testing.T) {
	reg := production.New(testLogger())
	msg := testRegisterMessage()
	msg.PrivacyCapabilities = nil
	p := reg.Register("p-nocaps", nil, msg)
	p.ChallengeVerifiedSIP = true
	reg.SetTrustLevel(p.ID, production.TrustHardware)
	reg.RecordChallengeSuccess(p.ID)

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Fatal("provider without privacy capabilities should not be routable for text models")
	}

	models := reg.ListModels()
	for _, m := range models {
		if m.ID == "mlx-community/Qwen3.5-9B-Instruct-4bit" {
			t.Fatal("text model from provider without privacy capabilities should not appear in model list")
		}
	}
}

func TestProviderWithoutManifestCheckExcludedFromTextRouting(t *testing.T) {
	reg := production.New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p-nomanifest", nil, msg)
	p.TrustLevel = production.TrustHardware
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true
	p.RuntimeManifestChecked = false

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Fatal("provider without manifest verification should not be routable for text models")
	}
}

func TestSwiftProviderRequiresRuntimeManifestCheck(t *testing.T) {
	reg := production.New(testLogger())
	msg := testRegisterMessage()
	msg.Backend = production.BackendMLXSwift
	p := reg.Register("p-swift", nil, msg)
	p.TrustLevel = production.TrustHardware
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = false

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Fatal("swift provider without manifest verification should not be routable for text models")
	}

	p.RuntimeManifestChecked = true
	found = findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found == nil {
		t.Fatal("swift provider should be routable once its runtime manifest is verified")
	}
}

func TestProviderWithoutChallengeVerifiedSIPExcluded(t *testing.T) {
	reg := production.New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p-nosip", nil, msg)
	p.TrustLevel = production.TrustHardware
	p.LastChallengeVerified = time.Now()
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = false

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Fatal("provider without coordinator-verified SIP should not be routable for text")
	}
}

func TestProviderPartialPrivacyCapsExcluded(t *testing.T) {
	reg := production.New(testLogger())
	msg := testRegisterMessage()
	msg.PrivacyCapabilities.EnvScrubbed = false // base cap required for all backends
	p := reg.Register("p-partial", nil, msg)
	p.ChallengeVerifiedSIP = true
	reg.SetTrustLevel(p.ID, production.TrustHardware)
	reg.RecordChallengeSuccess(p.ID)

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Fatal("provider with incomplete privacy capabilities should not be routable for text")
	}
}

func newRegistryWithEligibility() (*production.Registry, *production.ReservationPlanner) {
	var planner *production.ReservationPlanner
	r := production.NewWithDependencies(testLogger(), production.Dependencies{
		Reservations: func(actual *production.ReservationPlanner) production.ReservationPreparation {
			planner = actual
			return actual
		},
	})
	return r, planner
}

// TestCodeAttestationGate verifies the v0.6.0 APNs code-identity gate at the
// single routing chokepoint across the rollout policy: not configured (no
// regression), grace/observe (configured but un-enforced still routes), enforced
// (fail-closed when un-attested, routable when attested), and a live grace-to-enforce
// deadline flip that does NOT require the provider to reconnect.
func TestCodeAttestationGate(t *testing.T) {
	mk := func(r *production.Registry) *production.Provider {
		p := r.Register("p", nil, &protocol.RegisterMessage{
			Backend:                 production.BackendMLXSwift,
			PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
			EncryptedResponseChunks: true,
			PrivacyCapabilities: &protocol.PrivacyCapabilities{
				TextBackendInprocess: true,
				TextProxyDisabled:    true,
				AntiDebugEnabled:     true,
				CoreDumpsDisabled:    true,
				EnvScrubbed:          true,
			},
		})
		testMakeTextRoutable(p)
		return p
	}

	// Evaluate the gate under the registry read lease exactly as real callers do.
	supports := func(planner *production.ReservationPlanner, p *production.Provider) bool {
		eligibility := planner.PrepareEligibility()
		defer eligibility.Close()
		return eligibility.PrivateText(p.ID, time.Now())
	}

	// Not configured: routable regardless of CodeAttested (no fleet regression).
	r, planner := newRegistryWithEligibility()
	if !supports(planner, mk(r)) {
		t.Fatal("expected routable when code-attestation is not configured")
	}

	// Configured, no deadline (grace/observe): un-attested still routes.
	r, planner = newRegistryWithEligibility()
	r.SetCodeAttestationPolicy(true, time.Time{})
	if !supports(planner, mk(r)) {
		t.Fatal("expected routable in grace mode (configured, no deadline) even when !CodeAttested")
	}

	// Configured, deadline in the future (still grace): un-attested still routes.
	r, planner = newRegistryWithEligibility()
	r.SetCodeAttestationPolicy(true, time.Now().Add(time.Hour))
	if !supports(planner, mk(r)) {
		t.Fatal("expected routable while still inside the grace window")
	}

	// Enforced (deadline passed), not attested: blocked (fail-closed).
	r, planner = newRegistryWithEligibility()
	r.SetCodeAttestationPolicy(true, time.Now().Add(-time.Minute))
	if supports(planner, mk(r)) {
		t.Fatal("expected NOT routable once enforced and !CodeAttested")
	}

	// Enforced and attested: routable.
	r, planner = newRegistryWithEligibility()
	r.SetCodeAttestationPolicy(true, time.Now().Add(-time.Minute))
	pAtt := mk(r)
	pAtt.CodeAttested = true
	if !supports(planner, pAtt) {
		t.Fatal("expected routable when enforced and CodeAttested")
	}

	// Live deadline flip without reconnect: the SAME un-attested provider routes
	// during grace, then stops the instant the deadline moves into the past.
	r, planner = newRegistryWithEligibility()
	r.SetCodeAttestationConfigured(true)
	r.SetCodeAttestationDeadline(time.Now().Add(time.Hour)) // grace
	p := mk(r)
	if !supports(planner, p) {
		t.Fatal("expected routable during grace before the flip")
	}
	r.SetCodeAttestationDeadline(time.Now().Add(-time.Minute)) // enforce now
	if supports(planner, p) {
		t.Fatal("expected NOT routable after the deadline flips to the past")
	}
}

// TestVisionRoutingHelpers covers the per-provider vision capability check and
// the fleet-level fail-fast query that gate image/video routing. With a nil
// catalog the catalog filter allows all, so the gate reduces to "advertises this
// model id with IsVision".
func TestVisionRoutingHelpers(t *testing.T) {
	r, planner := newRegistryWithEligibility()
	visProv := r.Register("p-vis", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "gemma-4-26b", IsVision: true}},
	})
	textProv := r.Register("p-text", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "gemma-4-26b"}}, // text-only build of the same model
	})

	eligibility := planner.PrepareEligibility()
	visOK := eligibility.Vision(visProv.ID, "gemma-4-26b", false)
	textOK := eligibility.Vision(textProv.ID, "gemma-4-26b", false)
	eligibility.Close()
	if !visOK {
		t.Fatal("vision provider should serve gemma-4-26b as vision-capable")
	}
	if textOK {
		t.Fatal("text-only provider must NOT be vision-capable for gemma-4-26b")
	}

	// With a catalog that excludes the model, the public gate closes but the
	// owner self-route context (allowOffCatalog) still accepts the provider's
	// advertised VLM build - otherwise an owned off-catalog VLM would pass the
	// routable gate and then be starved by the vision gate.
	r.SetModelCatalog([]production.CatalogEntry{{ID: "some-other-model"}})
	eligibility = planner.PrepareEligibility()
	publicOK := eligibility.Vision(visProv.ID, "gemma-4-26b", false)
	ownerOK := eligibility.Vision(visProv.ID, "gemma-4-26b", true)
	ownerTextOK := eligibility.Vision(textProv.ID, "gemma-4-26b", true)
	eligibility.Close()
	if publicOK {
		t.Fatal("off-catalog model must not be vision-routable in the public context")
	}
	if !ownerOK {
		t.Fatal("off-catalog advertised VLM must be vision-routable in the owner self-route context")
	}
	if ownerTextOK {
		t.Fatal("owner context must still require a vision-capable build")
	}

	// The owner context lifts catalog MEMBERSHIP only: a build the catalog
	// tracks must still pass the weight-hash gate, mirroring the routable
	// gate's tamper tripwire.
	visProv.Mu().Lock()
	visProv.Models = []protocol.ModelInfo{{ID: "gemma-4-26b", IsVision: true, WeightHash: "tampered"}}
	visProv.Mu().Unlock()
	r.SetModelCatalog([]production.CatalogEntry{{ID: "gemma-4-26b", WeightHash: "expected"}})
	eligibility = planner.PrepareEligibility()
	ownerHashMismatchOK := eligibility.Vision(visProv.ID, "gemma-4-26b", true)
	eligibility.Close()
	if ownerHashMismatchOK {
		t.Fatal("owner context must not admit a catalog VLM with a mismatched weight hash")
	}
	visProv.Mu().Lock()
	visProv.Models = []protocol.ModelInfo{{ID: "gemma-4-26b", IsVision: true}}
	visProv.Mu().Unlock()
	r.SetModelCatalog(nil)

	if !r.HasVisionProviderForModel("gemma-4-26b") {
		t.Fatal("fleet has a vision provider for gemma-4-26b")
	}
	if r.HasVisionProviderForModel("gpt-oss-20b") {
		t.Fatal("no vision provider advertises gpt-oss-20b")
	}

	// An untrusted/offline vision provider must not satisfy the fleet check.
	visProv.Mu().Lock()
	visProv.Status = production.StatusUntrusted
	visProv.Mu().Unlock()
	if r.HasVisionProviderForModel("gemma-4-26b") {
		t.Fatal("an untrusted vision provider must not satisfy the fleet vision check")
	}
}

// TestNonSwiftBackendNotRoutable: only the Swift (mlx-swift) backend is
// routable; any other backend string is refused private text and routing.
func TestNonSwiftBackendNotRoutable(t *testing.T) {
	reg, planner := newRegistryWithEligibility()
	msg := testRegisterMessage()
	msg.Backend = "not-mlx-swift"

	p := reg.Register("p-non-swift", nil, msg)
	testMakeTextRoutable(p)

	eligibility := planner.PrepareEligibility()
	routable := eligibility.PrivateText(p.ID, time.Now())
	eligibility.Close()
	if routable {
		t.Fatal("non-Swift provider must not support private text")
	}

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Fatal("non-Swift provider must not be routable")
	}
}

func TestSwiftProviderMissingBaseCapsExcluded(t *testing.T) {
	reg, planner := newRegistryWithEligibility()
	msg := testRegisterMessage()
	msg.Backend = production.BackendMLXSwift
	msg.PrivacyCapabilities.AntiDebugEnabled = false

	p := reg.Register("p-swift-no-antidebug", nil, msg)
	testMakeTextRoutable(p)

	eligibility := planner.PrepareEligibility()
	routable := eligibility.PrivateText(p.ID, time.Now())
	eligibility.Close()
	if routable {
		t.Fatal("Swift provider without AntiDebugEnabled should NOT support private text")
	}

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Fatal("Swift provider without base privacy caps should not be routable")
	}
}
