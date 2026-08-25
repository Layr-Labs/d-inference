package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/hardwareadmission"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func admissionTestRegister() *protocol.RegisterMessage {
	return &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "MacBookAir10,1", ChipName: "Apple M1",
			ChipFamily: "M1", ChipTier: "Base", MemoryGB: 16, GPUCores: 8,
		},
		Backend: registry.BackendMLXSwift,
	}
}

func admissionTestAttestation(serial string) attestation.VerificationResult {
	return attestation.VerificationResult{
		Valid: true, SerialNumber: serial,
		HardwareModel: "MacBookAir10,1", ChipName: "Apple M1",
		MemoryGB: 16, GPUCores: 8, Timestamp: time.Now(),
	}
}

func TestHardwareAdmissionRejectsNewMachineBelowEnforcedFloor(t *testing.T) {
	srv, st := testServerWithConfig(t, ServerConfig{
		HardwareAdmissionMode:        "enforce",
		HardwareAdmissionMinMemoryGB: 32,
	})
	msg := admissionTestRegister()
	provider := srv.registry.Register("new-low-spec", nil, msg)
	provider.SetAttestationResult(ptrAdmissionResult(admissionTestAttestation("NEW-LOW-1")))

	if srv.evaluateProviderHardwareAdmission(provider.ID, provider, msg, admissionTestAttestation("NEW-LOW-1")) {
		t.Fatal("new low-spec machine was admitted")
	}
	if provider.HardwareAdmissionStatus() {
		t.Fatal("rejected provider marked hardware-admitted")
	}
	attempts, err := st.ListHardwareAdmissionAttempts(context.Background(), "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(attempts) != 1 || attempts[0].Decision != "rejected" ||
		attempts[0].ReasonCode != "hardware_below_minimum" {
		t.Fatalf("attempts = %+v", attempts)
	}
}

func TestHardwareAdmissionGrandfathersExistingTrustedSerial(t *testing.T) {
	st := store.NewMemory(store.Config{})
	now := time.Now()
	if err := st.UpsertProvider(context.Background(), store.ProviderRecord{
		ID: "legacy-session", SerialNumber: "LEGACY-LOW-1",
		Hardware: json.RawMessage(`{"memory_gb":16}`), Models: json.RawMessage(`[]`),
		Backend: registry.BackendMLXSwift, TrustLevel: string(registry.TrustHardware),
		RegisteredAt: now, LastSeen: now,
	}); err != nil {
		t.Fatal(err)
	}
	reg := registry.New(quietLogger())
	srv := NewServer(reg, st, ServerConfig{
		HardwareAdmissionMode:        "enforce",
		HardwareAdmissionMinMemoryGB: 32,
	}, quietLogger())
	msg := admissionTestRegister()
	provider := reg.Register("legacy-reconnect", nil, msg)

	if !srv.evaluateProviderHardwareAdmission(provider.ID, provider, msg, admissionTestAttestation("LEGACY-LOW-1")) {
		t.Fatal("grandfathered low-spec machine was rejected")
	}
	if !provider.HardwareAdmissionStatus() {
		t.Fatal("grandfathered provider not marked admitted")
	}
}

func TestHardwareAdmissionShadowAllowsAndRecordsWouldReject(t *testing.T) {
	srv, st := testServerWithConfig(t, ServerConfig{
		HardwareAdmissionMode:        "shadow",
		HardwareAdmissionMinMemoryGB: 32,
	})
	msg := admissionTestRegister()
	provider := srv.registry.Register("shadow-low", nil, msg)
	if !srv.evaluateProviderHardwareAdmission(provider.ID, provider, msg, admissionTestAttestation("SHADOW-1")) {
		t.Fatal("shadow policy blocked provider")
	}
	attempts, err := st.ListHardwareAdmissionAttempts(context.Background(), "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(attempts) != 1 || attempts[0].Decision != "would_reject" {
		t.Fatalf("attempts = %+v", attempts)
	}
}

func TestHardwareAdmissionCommitsOnlyAfterBoundDeviceIdentity(t *testing.T) {
	srv, st := testServerWithConfig(t, ServerConfig{
		HardwareAdmissionMode:        "enforce",
		HardwareAdmissionMinMemoryGB: 16,
	})
	msg := admissionTestRegister()
	provider := srv.registry.Register("new-qualified", nil, msg)
	result := admissionTestAttestation("NEW-QUALIFIED-1")
	provider.SetAttestationResult(&result)

	if !srv.evaluateProviderHardwareAdmission(provider.ID, provider, msg, result) {
		t.Fatal("qualified hardware was rejected before identity verification")
	}
	if provider.HardwareAdmissionStatus() {
		t.Fatal("new hardware admitted before MDA identity binding")
	}
	if admitted, _ := st.IsHardwareAdmitted(context.Background(), result.SerialNumber); admitted {
		t.Fatal("positive admission persisted before MDA identity binding")
	}

	provider.Mu().Lock()
	provider.TrustLevel = registry.TrustHardware
	provider.MDAVerified = true
	provider.SEKeyBound = true
	provider.Mu().Unlock()
	if srv.finalizePendingHardwareAdmission(provider) {
		t.Fatal("hardware admission finalized before official-code attestation")
	}
	provider.SetCodeAttested(true)
	if !srv.finalizePendingHardwareAdmission(provider) {
		t.Fatal("bound, qualified hardware did not finalize")
	}
	if admitted, err := st.IsHardwareAdmitted(context.Background(), result.SerialNumber); err != nil || !admitted {
		t.Fatalf("persisted admission = (%v,%v)", admitted, err)
	}
}

func TestEnforcementReconciliationStagesUnboundConnection(t *testing.T) {
	srv, st := testServerWithConfig(t, ServerConfig{
		HardwareAdmissionMode:        "shadow",
		HardwareAdmissionMinMemoryGB: 16,
	})
	msg := admissionTestRegister()
	provider := srv.registry.Register("connected-before-enforce", nil, msg)
	result := admissionTestAttestation("CONNECTED-BEFORE-ENFORCE")
	provider.SetAttestationResult(&result)

	current := srv.hardwareAdmissionPolicySnapshot()
	enforce, err := st.ActivateHardwareAdmissionPolicy(
		context.Background(),
		hardwareadmission.Policy{
			Mode: hardwareadmission.ModeEnforce, MinMemoryGB: 16,
			CatalogVersion: hardwareadmission.CatalogVersion,
		},
		current.Version,
	)
	if err != nil {
		t.Fatal(err)
	}
	srv.setHardwareAdmissionPolicy(enforce)
	if err := srv.reconcileConnectedHardwareAdmissions(enforce); err != nil {
		t.Fatal(err)
	}
	if provider.HardwareAdmissionStatus() {
		t.Fatal("reconciliation admitted a connection without MDA/code identity")
	}
	if !srv.hasPendingHardwareAdmission(provider.ID) {
		t.Fatal("qualified connection was not staged for identity finalization")
	}
	if admitted, _ := st.IsHardwareAdmitted(context.Background(), result.SerialNumber); admitted {
		t.Fatal("reconciliation persisted an unbound positive admission")
	}
}

func TestProviderRequirementsAndAdminPolicyEndpoints(t *testing.T) {
	srv, _ := testServerWithConfig(t, ServerConfig{AdminKey: "test-key"})

	getReq := httptest.NewRequest(http.MethodGet, "/v1/provider-requirements", nil)
	getW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(getW, getReq)
	if getW.Code != http.StatusOK {
		t.Fatalf("requirements status = %d: %s", getW.Code, getW.Body.String())
	}
	if !strings.Contains(getW.Body.String(), hardwareadmission.CatalogVersion) {
		t.Fatalf("requirements missing catalog version: %s", getW.Body.String())
	}

	body := `{"mode":"shadow","min_memory_gb":32,"min_memory_bandwidth_gbs":200,"reason":"rollout","expected_current_version":0}`
	putReq := httptest.NewRequest(http.MethodPut, "/v1/admin/hardware-admission/policy", strings.NewReader(body))
	putReq.Header.Set("Authorization", "Bearer test-key")
	putReq.Header.Set("Content-Type", "application/json")
	putW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(putW, putReq)
	if putW.Code != http.StatusOK {
		t.Fatalf("admin put status = %d: %s", putW.Code, putW.Body.String())
	}
	var policy hardwareadmission.Policy
	if err := json.Unmarshal(putW.Body.Bytes(), &policy); err != nil {
		t.Fatal(err)
	}
	if policy.Version == 0 || policy.Mode != hardwareadmission.ModeShadow || policy.MinMemoryGB != 32 {
		t.Fatalf("policy = %+v", policy)
	}
	publicReq := httptest.NewRequest(http.MethodGet, "/v1/provider-requirements", nil)
	publicW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(publicW, publicReq)
	if strings.Contains(publicW.Body.String(), "rollout") ||
		strings.Contains(publicW.Body.String(), "admin-key") {
		t.Fatalf("public policy leaked operator audit fields: %s", publicW.Body.String())
	}
}

type failingHardwarePolicyStore struct {
	store.Store
}

func (f failingHardwarePolicyStore) GetActiveHardwareAdmissionPolicy(context.Context) (*hardwareadmission.Policy, error) {
	return nil, errors.New("database unavailable")
}

func TestHardwareAdmissionBootstrapFailureFailsClosed(t *testing.T) {
	base := store.NewMemory(store.Config{})
	reg := registry.New(quietLogger())
	_ = NewServer(reg, failingHardwarePolicyStore{Store: base}, ServerConfig{
		HardwareAdmissionMode:        "enforce",
		HardwareAdmissionMinMemoryGB: 32,
	}, quietLogger())
	if !reg.HardwareAdmissionEnforced() {
		t.Fatal("bootstrap store failure disabled hardware enforcement")
	}
}

func TestHardwareAdmissionPolicyPublicationIsMonotonic(t *testing.T) {
	srv, _ := testServer(t)
	newer := hardwareadmission.Policy{
		Version: 2, Mode: hardwareadmission.ModeEnforce,
		CatalogVersion: hardwareadmission.CatalogVersion,
	}
	srv.setHardwareAdmissionPolicy(newer)
	applied, err := srv.applyHardwareAdmissionPolicy(hardwareadmission.Policy{
		Version: 1, Mode: hardwareadmission.ModeShadow,
		CatalogVersion: hardwareadmission.CatalogVersion,
	})
	if err != nil {
		t.Fatal(err)
	}
	if applied {
		t.Fatal("older policy overwrote newer in-memory enforcement")
	}
	if got := srv.hardwareAdmissionPolicySnapshot(); got.Version != 2 ||
		got.Mode != hardwareadmission.ModeEnforce {
		t.Fatalf("active policy = %+v", got)
	}
	if !srv.registry.HardwareAdmissionEnforced() {
		t.Fatal("stale shadow policy disabled registry enforcement")
	}
}

func TestPendingAdmissionGenerationCannotClearNewerPolicy(t *testing.T) {
	srv, _ := testServer(t)
	srv.stagePendingHardwareAdmission("provider-generation", pendingHardwareAdmission{
		policy: hardwareadmission.Policy{Version: 1},
	})
	srv.stagePendingHardwareAdmission("provider-generation", pendingHardwareAdmission{
		policy: hardwareadmission.Policy{Version: 2},
	})
	if srv.clearPendingHardwareAdmissionIf("provider-generation", 1) {
		t.Fatal("stale finalizer cleared newer pending policy")
	}
	srv.hardwareAdmissionPendingMu.Lock()
	pending := srv.hardwareAdmissionPending["provider-generation"]
	srv.hardwareAdmissionPendingMu.Unlock()
	if pending.policy.Version != 2 {
		t.Fatalf("pending policy = %d, want 2", pending.policy.Version)
	}
}

func TestEnforcedHardwareTrustRequiresCodeIdentity(t *testing.T) {
	srv, _ := testServer(t)
	srv.setHardwareAdmissionPolicy(hardwareadmission.Policy{
		Version: 1, Mode: hardwareadmission.ModeEnforce,
		CatalogVersion: hardwareadmission.CatalogVersion,
	})
	provider := srv.registry.Register("code-gated-grant", nil, admissionTestRegister())
	provider.Mu().Lock()
	provider.TrustLevel = registry.TrustSelfSigned
	provider.Mu().Unlock()
	if srv.grantProviderHardwareTrust(provider) {
		t.Fatal("enforce-mode MDM grant succeeded without code identity")
	}
	if provider.GetTrustLevel() != registry.TrustSelfSigned {
		t.Fatal("failed code-gated grant changed provider trust")
	}
	provider.SetCodeAttested(true)
	if !srv.grantProviderHardwareTrust(provider) {
		t.Fatal("code-attested provider did not receive hardware trust")
	}
}

func ptrAdmissionResult(result attestation.VerificationResult) *attestation.VerificationResult {
	return &result
}
