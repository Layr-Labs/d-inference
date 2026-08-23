package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestCodeAttestationGate verifies the v0.6.0 APNs code-identity gate at the
// single routing chokepoint across the rollout policy: not configured (no
// regression), grace/observe (configured but un-enforced still routes), enforced
// (fail-closed when un-attested, routable when attested), and a live grace→enforce
// deadline flip that does NOT require the provider to reconnect.
func TestCodeAttestationGate(t *testing.T) {
	mk := func() *Provider {
		p := &Provider{
			Backend:                 BackendMLXSwift,
			PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
			EncryptedResponseChunks: true,
			PrivacyCapabilities: &protocol.PrivacyCapabilities{
				TextBackendInprocess: true,
				TextProxyDisabled:    true,
				AntiDebugEnabled:     true,
				CoreDumpsDisabled:    true,
				EnvScrubbed:          true,
			},
		}
		testMakeTextRoutable(p)
		return p
	}

	// Evaluate the gate under r.mu exactly as real callers do.
	supports := func(r *Registry, p *Provider) bool {
		r.mu.RLock()
		defer r.mu.RUnlock()
		return r.providerSupportsPrivateTextLocked(p)
	}

	// Not configured: routable regardless of CodeAttested (no fleet regression).
	r := New(testLogger())
	if !supports(r, mk()) {
		t.Fatal("expected routable when code-attestation is not configured")
	}

	// Configured, no deadline (grace/observe): un-attested still routes.
	r = New(testLogger())
	r.SetCodeAttestationPolicy(true, time.Time{})
	if !supports(r, mk()) {
		t.Fatal("expected routable in grace mode (configured, no deadline) even when !CodeAttested")
	}

	// Configured, deadline in the future (still grace): un-attested still routes.
	r = New(testLogger())
	r.SetCodeAttestationPolicy(true, time.Now().Add(time.Hour))
	if !supports(r, mk()) {
		t.Fatal("expected routable while still inside the grace window")
	}

	// Enforced (deadline passed), not attested: blocked (fail-closed).
	r = New(testLogger())
	r.SetCodeAttestationPolicy(true, time.Now().Add(-time.Minute))
	if supports(r, mk()) {
		t.Fatal("expected NOT routable once enforced and !CodeAttested")
	}

	// Enforced and attested: routable.
	r = New(testLogger())
	r.SetCodeAttestationPolicy(true, time.Now().Add(-time.Minute))
	pAtt := mk()
	pAtt.CodeAttested = true
	if !supports(r, pAtt) {
		t.Fatal("expected routable when enforced and CodeAttested")
	}

	// Live deadline flip without reconnect: the SAME un-attested provider routes
	// during grace, then stops the instant the deadline moves into the past.
	r = New(testLogger())
	r.SetCodeAttestationConfigured(true)
	r.SetCodeAttestationDeadline(time.Now().Add(time.Hour)) // grace
	p := mk()
	if !supports(r, p) {
		t.Fatal("expected routable during grace before the flip")
	}
	r.SetCodeAttestationDeadline(time.Now().Add(-time.Minute)) // enforce now
	if supports(r, p) {
		t.Fatal("expected NOT routable after the deadline flips to the past")
	}
}

func TestRegisterAndGetProvider(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	p := reg.Register("p1", nil, msg)

	if p.ID != "p1" {
		t.Errorf("id = %q, want %q", p.ID, "p1")
	}
	if p.Status != StatusOnline {
		t.Errorf("status = %q, want %q", p.Status, StatusOnline)
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
	reg := New(testLogger())
	msg := testRegisterMessage()
	msg.PrivacyCapabilities = nil
	p := reg.Register("p-nocaps", nil, msg)
	p.ChallengeVerifiedSIP = true
	reg.SetTrustLevel(p.ID, TrustHardware)
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
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p-nomanifest", nil, msg)
	p.TrustLevel = TrustHardware
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true
	p.RuntimeManifestChecked = false

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Fatal("provider without manifest verification should not be routable for text models")
	}
}

func TestSwiftProviderRequiresRuntimeManifestCheck(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	msg.Backend = BackendMLXSwift
	p := reg.Register("p-swift", nil, msg)
	p.TrustLevel = TrustHardware
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
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p-nosip", nil, msg)
	p.TrustLevel = TrustHardware
	p.LastChallengeVerified = time.Now()
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = false

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Fatal("provider without coordinator-verified SIP should not be routable for text")
	}
}

// TestVisionRoutingHelpers covers the per-provider vision capability check and
// the fleet-level fail-fast query that gate image/video routing. With a nil
// catalog the catalog filter allows all, so the gate reduces to "advertises this
// model id with IsVision".
func TestVisionRoutingHelpers(t *testing.T) {
	r := New(testLogger())
	visProv := &Provider{
		ID:     "p-vis",
		Status: StatusOnline,
		Models: []protocol.ModelInfo{{ID: "gemma-4-26b", IsVision: true}},
	}
	textProv := &Provider{
		ID:     "p-text",
		Status: StatusOnline,
		Models: []protocol.ModelInfo{{ID: "gemma-4-26b"}}, // text-only build of the same model
	}
	r.providers["p-vis"] = visProv
	r.providers["p-text"] = textProv

	r.mu.RLock()
	visOK := r.providerServesVisionModelLocked(visProv, "gemma-4-26b", false)
	textOK := r.providerServesVisionModelLocked(textProv, "gemma-4-26b", false)
	r.mu.RUnlock()
	if !visOK {
		t.Fatal("vision provider should serve gemma-4-26b as vision-capable")
	}
	if textOK {
		t.Fatal("text-only provider must NOT be vision-capable for gemma-4-26b")
	}

	// With a catalog that excludes the model, the public gate closes but the
	// owner self-route context (allowOffCatalog) still accepts the provider's
	// advertised VLM build — otherwise an owned off-catalog VLM would pass the
	// routable gate and then be starved by the vision gate.
	r.SetModelCatalog([]CatalogEntry{{ID: "some-other-model"}})
	r.mu.RLock()
	publicOK := r.providerServesVisionModelLocked(visProv, "gemma-4-26b", false)
	ownerOK := r.providerServesVisionModelLocked(visProv, "gemma-4-26b", true)
	ownerTextOK := r.providerServesVisionModelLocked(textProv, "gemma-4-26b", true)
	r.mu.RUnlock()
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
	visProv.Models = []protocol.ModelInfo{{ID: "gemma-4-26b", IsVision: true, WeightHash: "tampered"}}
	r.SetModelCatalog([]CatalogEntry{{ID: "gemma-4-26b", WeightHash: "expected"}})
	r.mu.RLock()
	ownerHashMismatchOK := r.providerServesVisionModelLocked(visProv, "gemma-4-26b", true)
	r.mu.RUnlock()
	if ownerHashMismatchOK {
		t.Fatal("owner context must not admit a catalog VLM with a mismatched weight hash")
	}
	visProv.Models = []protocol.ModelInfo{{ID: "gemma-4-26b", IsVision: true}}
	r.SetModelCatalog(nil)

	if !r.HasVisionProviderForModel("gemma-4-26b") {
		t.Fatal("fleet has a vision provider for gemma-4-26b")
	}
	if r.HasVisionProviderForModel("gpt-oss-20b") {
		t.Fatal("no vision provider advertises gpt-oss-20b")
	}

	// An untrusted/offline vision provider must not satisfy the fleet check.
	visProv.Status = StatusUntrusted
	if r.HasVisionProviderForModel("gemma-4-26b") {
		t.Fatal("an untrusted vision provider must not satisfy the fleet vision check")
	}
}

func TestSwiftProviderPrivateTextWithoutPythonCaps(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	msg.Backend = BackendMLXSwift
	msg.PrivacyCapabilities.PythonRuntimeLocked = false
	msg.PrivacyCapabilities.DangerousModulesBlocked = false

	p := reg.Register("p-swift-nopython", nil, msg)
	testMakeTextRoutable(p)

	reg.mu.RLock()
	routable := reg.providerSupportsPrivateTextLocked(p)
	reg.mu.RUnlock()
	if !routable {
		t.Fatal("Swift provider should support private text without PythonRuntimeLocked/DangerousModulesBlocked")
	}

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found == nil {
		t.Fatal("Swift provider without Python caps should be routable for text models")
	}
}

func TestPythonProviderDeprecatedNotRoutable(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	msg.Backend = "inprocess-mlx" // intentionally legacy backend

	p := reg.Register("p-python-deprecated", nil, msg)
	testMakeTextRoutable(p)

	reg.mu.RLock()
	routable := reg.providerSupportsPrivateTextLocked(p)
	reg.mu.RUnlock()
	if routable {
		t.Fatal("Python (inprocess-mlx) provider should NOT support private text — backend is deprecated")
	}

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Fatal("deprecated Python provider should not be routable")
	}
}

func TestSwiftProviderMissingBaseCapsExcluded(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	msg.Backend = BackendMLXSwift
	msg.PrivacyCapabilities.PythonRuntimeLocked = false
	msg.PrivacyCapabilities.DangerousModulesBlocked = false
	msg.PrivacyCapabilities.AntiDebugEnabled = false

	p := reg.Register("p-swift-no-antidebug", nil, msg)
	testMakeTextRoutable(p)

	reg.mu.RLock()
	routable := reg.providerSupportsPrivateTextLocked(p)
	reg.mu.RUnlock()
	if routable {
		t.Fatal("Swift provider without AntiDebugEnabled should NOT support private text")
	}

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Fatal("Swift provider without base privacy caps should not be routable")
	}
}

func TestProviderPartialPrivacyCapsExcluded(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	msg.PrivacyCapabilities.EnvScrubbed = false // base cap required for all backends
	p := reg.Register("p-partial", nil, msg)
	p.ChallengeVerifiedSIP = true
	reg.SetTrustLevel(p.ID, TrustHardware)
	reg.RecordChallengeSuccess(p.ID)

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found != nil {
		t.Fatal("provider with incomplete privacy capabilities should not be routable for text")
	}
}

func TestBenchmarkFieldsInRegistration(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	msg.PrefillTPS = 500.0
	msg.DecodeTPS = 100.0

	p := reg.Register("p1", nil, msg)
	if p.PrefillTPS != 500.0 {
		t.Errorf("prefill_tps = %f, want 500.0", p.PrefillTPS)
	}
	if p.DecodeTPS != 100.0 {
		t.Errorf("decode_tps = %f, want 100.0", p.DecodeTPS)
	}
}

func TestPendingRequests(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	pr := &PendingRequest{
		RequestID:  "req-1",
		ChunkCh:    make(chan string, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
	}
	p.AddPending(pr)

	if p.PendingCount() != 1 {
		t.Errorf("pending count = %d, want 1", p.PendingCount())
	}

	got := p.GetPending("req-1")
	if got == nil {
		t.Fatal("GetPending returned nil")
	}
	if got.RequestID != "req-1" {
		t.Errorf("request_id = %q", got.RequestID)
	}

	removed := p.RemovePending("req-1")
	if removed == nil {
		t.Fatal("RemovePending returned nil")
	}
	if p.PendingCount() != 0 {
		t.Errorf("pending count after remove = %d", p.PendingCount())
	}
}
