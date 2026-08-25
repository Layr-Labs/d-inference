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
	"github.com/eigeninference/d-inference/coordinator/mdm"
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

func TestHardwareAdmissionAllowsStaleReconnectForDurablyAdmittedMachine(t *testing.T) {
	st := store.NewMemory(store.Config{})
	now := time.Now()
	if err := st.UpsertProvider(context.Background(), store.ProviderRecord{
		ID: "legacy-session", SerialNumber: "LEGACY-STALE-1",
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
	provider := reg.Register("legacy-stale-reconnect", nil, msg)
	result := admissionTestAttestation("LEGACY-STALE-1")
	result.Timestamp = time.Now().Add(-time.Hour)

	if !srv.evaluateProviderHardwareAdmission(provider.ID, provider, msg, result) {
		t.Fatal("durably admitted provider was rejected for a stale reconnect attestation")
	}
	if !provider.HardwareAdmissionStatus() {
		t.Fatal("durably admitted reconnect was not marked admitted")
	}
}

func TestDurablyAdmittedReconnectRejectsUnsignedHardwareMutation(t *testing.T) {
	st := store.NewMemory(store.Config{})
	now := time.Now()
	if err := st.UpsertProvider(context.Background(), store.ProviderRecord{
		ID: "legacy-session", SerialNumber: "LEGACY-MUTATED-1",
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
	msg.Hardware.MemoryGB = 128
	provider := reg.Register("legacy-mutated-reconnect", nil, msg)
	result := admissionTestAttestation("LEGACY-MUTATED-1")

	if srv.evaluateProviderHardwareAdmission(provider.ID, provider, msg, result) {
		t.Fatal("durably admitted provider bypassed signed hardware consistency")
	}
	if provider.HardwareAdmissionStatus() {
		t.Fatal("mutated reconnect was marked admitted")
	}
	attempts, err := st.ListHardwareAdmissionAttempts(
		context.Background(), "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(attempts) != 1 ||
		attempts[0].ReasonCode != "hardware_claim_mismatch" {
		t.Fatalf("attempts = %+v", attempts)
	}
}

func TestDurableLegacyReconnectUsesAdmissionHardware(t *testing.T) {
	srv, st := testServerWithConfig(t, ServerConfig{
		HardwareAdmissionMode:        "enforce",
		HardwareAdmissionMinMemoryGB: 8,
	})
	const serial = "LEGACY-OPTIONAL-HARDWARE"
	policy := srv.hardwareAdmissionPolicySnapshot()
	if err := st.AdmitHardware(context.Background(), store.HardwareAdmission{
		SerialNumber:  serial,
		Source:        "grandfathered",
		PolicyVersion: policy.Version,
		Hardware: hardwareadmission.Observed{
			MachineModel: "MacBookAir10,1",
			ChipName:     "Apple M1",
			ChipFamily:   "M1",
			ChipTier:     "Base",
			MemoryGB:     16,
			GPUCores:     8,
		},
	}); err != nil {
		t.Fatal(err)
	}
	msg := admissionTestRegister()
	msg.Hardware.MemoryGB = 512
	msg.Hardware.GPUCores = 512
	provider := srv.registry.RegisterPendingHardwareAdmission(
		"legacy-optional-hardware", nil, msg)
	result := admissionTestAttestation(serial)
	result.MemoryGB = 0
	result.GPUCores = 0

	if !srv.evaluateProviderHardwareAdmission(
		provider.ID, provider, msg, result) {
		t.Fatal("durable legacy provider with omitted optional claims was rejected")
	}
	provider.Mu().Lock()
	hardware := provider.Hardware
	provider.Mu().Unlock()
	if hardware.MemoryGB != 16 || hardware.GPUCores != 8 {
		t.Fatalf("live hardware = %+v, want durable 16 GiB / 8 GPU cores", hardware)
	}
}

func TestHardwareAdmissionRejectsMissingSignedIdentityFields(t *testing.T) {
	for _, field := range []string{"machine_model", "chip_name"} {
		t.Run(field, func(t *testing.T) {
			srv, st := testServerWithConfig(t, ServerConfig{
				HardwareAdmissionMode:        "enforce",
				HardwareAdmissionMinMemoryGB: 8,
			})
			msg := admissionTestRegister()
			result := admissionTestAttestation("MISSING-SIGNED-" + field)
			if field == "machine_model" {
				result.HardwareModel = ""
			} else {
				result.ChipName = ""
			}
			provider := srv.registry.RegisterPendingHardwareAdmission(
				"missing-signed-"+field, nil, msg)

			if srv.evaluateProviderHardwareAdmission(
				provider.ID, provider, msg, result) {
				t.Fatal("provider with missing signed identity was admitted")
			}
			attempts, err := st.ListHardwareAdmissionAttempts(
				context.Background(), "", 10)
			if err != nil {
				t.Fatal(err)
			}
			if len(attempts) != 1 ||
				attempts[0].ReasonCode != "hardware_identity_required" {
				t.Fatalf("attempts = %+v", attempts)
			}
		})
	}
}

func TestHardwareAdmissionRejectsStaleAttestationForNewMachine(t *testing.T) {
	srv, _ := testServerWithConfig(t, ServerConfig{
		HardwareAdmissionMode:        "enforce",
		HardwareAdmissionMinMemoryGB: 16,
	})
	msg := admissionTestRegister()
	provider := srv.registry.Register("new-stale", nil, msg)
	result := admissionTestAttestation("NEW-STALE-1")
	result.Timestamp = time.Now().Add(-time.Hour)

	if srv.evaluateProviderHardwareAdmission(provider.ID, provider, msg, result) {
		t.Fatal("new machine with stale attestation was admitted")
	}
	if provider.HardwareAdmissionStatus() {
		t.Fatal("stale new machine was marked admitted")
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
	provider.MDAFreshnessVerified = true
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

func TestEnforcePolicyActivationRequiresIdentityDependencies(t *testing.T) {
	srv, _ := testServerWithConfig(t, ServerConfig{AdminKey: "test-key"})
	body := `{"mode":"enforce","min_memory_gb":32,"reason":"launch","expected_current_version":0}`

	put := func() *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(
			http.MethodPut,
			"/v1/admin/hardware-admission/policy",
			strings.NewReader(body),
		)
		req.Header.Set("Authorization", "Bearer test-key")
		req.Header.Set("Content-Type", "application/json")
		response := httptest.NewRecorder()
		srv.Handler().ServeHTTP(response, req)
		return response
	}

	if response := put(); response.Code != http.StatusConflict {
		t.Fatalf("missing-dependency status = %d, want 409: %s",
			response.Code, response.Body.String())
	}

	srv.SetMDMClient(mdm.NewClient("http://mdm.invalid", "test", quietLogger()))
	srv.SetCodeAttestor(&fakeCodeAttestor{
		onSend: func(_, _, _, _ string) error { return nil },
	})
	if response := put(); response.Code != http.StatusOK {
		t.Fatalf("ready enforce status = %d, want 200: %s",
			response.Code, response.Body.String())
	}
}

func TestHardwareAdmissionStartupReadiness(t *testing.T) {
	srv, _ := testServerWithConfig(t, ServerConfig{
		HardwareAdmissionMode:        "enforce",
		HardwareAdmissionMinMemoryGB: 16,
	})
	if err := srv.ValidateHardwareAdmissionReadiness(); err == nil {
		t.Fatal("enforce startup passed without MDM and code attestation")
	}
	srv.SetMDMClient(mdm.NewClient(
		"http://mdm.invalid", "test", quietLogger()))
	srv.SetCodeAttestor(&fakeCodeAttestor{
		onSend: func(_, _, _, _ string) error { return nil },
	})
	if err := srv.ValidateHardwareAdmissionReadiness(); err != nil {
		t.Fatalf("launch-safe enforce startup rejected: %v", err)
	}
}

func TestFirstEnforcementGrandfathersLiveTrustedProvider(t *testing.T) {
	srv, st := testServerWithConfig(t, ServerConfig{AdminKey: "test-key"})
	srv.SetMDMClient(mdm.NewClient("http://mdm.invalid", "test", quietLogger()))
	srv.SetCodeAttestor(&fakeCodeAttestor{
		onSend: func(_, _, _, _ string) error { return nil },
	})

	provider := srv.registry.RegisterPendingHardwareAdmission(
		"live-grandfather", nil, admissionTestRegister())
	result := admissionTestAttestation("LIVE-GRANDFATHER-SERIAL")
	provider.SetAttestationResult(&result)
	provider.SetAttested(true, registry.TrustHardware)

	body := `{"mode":"enforce","min_memory_gb":32,"reason":"launch","expected_current_version":0}`
	req := httptest.NewRequest(
		http.MethodPut,
		"/v1/admin/hardware-admission/policy",
		strings.NewReader(body),
	)
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	srv.Handler().ServeHTTP(response, req)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", response.Code, response.Body.String())
	}

	admitted, err := st.IsHardwareAdmitted(
		context.Background(), "LIVE-GRANDFATHER-SERIAL")
	if err != nil || !admitted {
		t.Fatalf("live trusted admission = (%v,%v), want true,nil", admitted, err)
	}
	if !provider.HardwareAdmissionStatus() || !provider.PersistenceEnabled() {
		t.Fatal("live grandfathered provider was not committed")
	}
}

func TestFirstEnforcementGrandfathersLegacySignedCapacityOmission(t *testing.T) {
	srv, st := testServerWithConfig(t, ServerConfig{AdminKey: "test-key"})
	srv.SetMDMClient(mdm.NewClient("http://mdm.invalid", "test", quietLogger()))
	srv.SetCodeAttestor(&fakeCodeAttestor{
		onSend: func(_, _, _, _ string) error { return nil },
	})

	registration := admissionTestRegister()
	provider := srv.registry.RegisterPendingHardwareAdmission(
		"legacy-live-grandfather", nil, registration)
	result := admissionTestAttestation("LEGACY-LIVE-GRANDFATHER")
	result.MemoryGB = 0
	result.GPUCores = 0
	provider.SetAttestationResult(&result)
	provider.SetAttested(true, registry.TrustHardware)

	body := `{"mode":"enforce","min_memory_gb":48,"reason":"launch","expected_current_version":0}`
	request := httptest.NewRequest(
		http.MethodPut, "/v1/admin/hardware-admission/policy",
		strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer test-key")
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	srv.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", response.Code, response.Body.String())
	}

	admission, err := st.GetHardwareAdmission(
		context.Background(), result.SerialNumber)
	if err != nil || admission == nil {
		t.Fatalf("legacy live admission = (%+v,%v), want durable admission", admission, err)
	}
	if admission.Hardware.MemoryGB != registration.Hardware.MemoryGB ||
		admission.Hardware.GPUCores != registration.Hardware.GPUCores {
		t.Fatalf("durable hardware = %+v, want registration snapshot", admission.Hardware)
	}
	if !provider.HardwareAdmissionStatus() {
		t.Fatal("legacy live grandfather was fenced during first enforcement")
	}
}

func TestFirstEnforcementRejectsLiveUnsignedHardwareMutation(t *testing.T) {
	srv, st := testServerWithConfig(t, ServerConfig{AdminKey: "test-key"})
	srv.SetMDMClient(mdm.NewClient(
		"http://mdm.invalid", "test", quietLogger()))
	srv.SetCodeAttestor(&fakeCodeAttestor{
		onSend: func(_, _, _, _ string) error { return nil },
	})
	registration := admissionTestRegister()
	registration.Hardware.MemoryGB = 128
	provider := srv.registry.RegisterPendingHardwareAdmission(
		"live-mutated-grandfather", nil, registration)
	result := admissionTestAttestation("LIVE-MUTATED-GRANDFATHER")
	provider.SetAttestationResult(&result)
	provider.SetAttested(true, registry.TrustHardware)

	body := `{"mode":"enforce","min_memory_gb":16,"reason":"launch","expected_current_version":0}`
	request := httptest.NewRequest(
		http.MethodPut, "/v1/admin/hardware-admission/policy",
		strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer test-key")
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	srv.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", response.Code, response.Body.String())
	}
	admitted, err := st.IsHardwareAdmitted(
		context.Background(), result.SerialNumber)
	if err != nil {
		t.Fatal(err)
	}
	if admitted || provider.HardwareAdmissionStatus() {
		t.Fatal("mutated live hardware crossed the grandfathering cutoff")
	}
	attempts, err := st.ListHardwareAdmissionAttempts(
		context.Background(), "", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(attempts) != 1 ||
		attempts[0].ReasonCode != "hardware_claim_mismatch" {
		t.Fatalf("attempts = %+v", attempts)
	}
}

func TestThresholdRollbackDoesNotRestoreRevokedProvider(t *testing.T) {
	srv, st := testServer(t)
	enforce, err := st.ActivateHardwareAdmissionPolicy(
		context.Background(),
		hardwareadmission.Policy{
			Mode: hardwareadmission.ModeEnforce, MinMemoryGB: 16,
			CatalogVersion: hardwareadmission.CatalogVersion,
		},
		0,
	)
	if err != nil {
		t.Fatal(err)
	}
	const serial = "REVOKED-ROLLBACK-SERIAL"
	if err := st.AdmitHardware(context.Background(), store.HardwareAdmission{
		SerialNumber: serial, PolicyVersion: enforce.Version,
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.RevokeHardwareAdmission(
		context.Background(), serial, "test", "retired"); err != nil {
		t.Fatal(err)
	}

	provider := srv.registry.Register("revoked-rollback", nil, admissionTestRegister())
	provider.SetAttestationResult(&attestation.VerificationResult{
		Valid: true, SerialNumber: serial,
	})
	srv.setHardwareAdmissionPolicy(enforce)
	shadow, err := st.ActivateHardwareAdmissionPolicy(
		context.Background(),
		hardwareadmission.Policy{
			Mode: hardwareadmission.ModeShadow, MinMemoryGB: 16,
			CatalogVersion: hardwareadmission.CatalogVersion,
		},
		enforce.Version,
	)
	if err != nil {
		t.Fatal(err)
	}
	applied, err := srv.applyHardwareAdmissionPolicy(shadow)
	if err != nil || !applied {
		t.Fatalf("apply rollback = (%v,%v)", applied, err)
	}
	if srv.registry.ProviderHardwareAdmitted(provider) {
		t.Fatal("shadow rollback restored a revoked provider")
	}
	if !provider.HardwareAdmissionRevokedStatus() {
		t.Fatal("revocation fence was not retained on the live provider")
	}
}

type blockingRevocationStore struct {
	store.Store
	block   bool
	checked chan struct{}
	release chan struct{}
}

func (s *blockingRevocationStore) IsHardwareAdmissionRevoked(
	ctx context.Context,
	serial string,
) (bool, error) {
	revoked, err := s.Store.IsHardwareAdmissionRevoked(ctx, serial)
	if s.block {
		close(s.checked)
		select {
		case <-s.release:
		case <-ctx.Done():
			return false, ctx.Err()
		}
	}
	return revoked, err
}

func TestConcurrentRollbackAndRevocationCannotResurrectProvider(t *testing.T) {
	base := store.NewMemory(store.Config{})
	enforce, err := base.ActivateHardwareAdmissionPolicy(
		context.Background(),
		hardwareadmission.Policy{
			Mode: hardwareadmission.ModeEnforce, MinMemoryGB: 16,
			CatalogVersion: hardwareadmission.CatalogVersion,
		},
		0,
	)
	if err != nil {
		t.Fatal(err)
	}
	const serial = "REVOKE-ROLLBACK-RACE"
	if err := base.AdmitHardware(context.Background(), store.HardwareAdmission{
		SerialNumber: serial, PolicyVersion: enforce.Version,
	}); err != nil {
		t.Fatal(err)
	}
	wrapped := &blockingRevocationStore{
		Store: base, checked: make(chan struct{}), release: make(chan struct{}),
	}
	reg := registry.New(quietLogger())
	srv := NewServer(reg, wrapped, ServerConfig{AdminKey: "test-key"}, quietLogger())
	provider := reg.Register("revoke-rollback-race", nil, admissionTestRegister())
	provider.SetAttestationResult(&attestation.VerificationResult{
		Valid: true, SerialNumber: serial,
	})
	reg.SetProviderHardwareAdmitted(provider, true)
	shadow, err := base.ActivateHardwareAdmissionPolicy(
		context.Background(),
		hardwareadmission.Policy{
			Mode: hardwareadmission.ModeShadow, MinMemoryGB: 16,
			CatalogVersion: hardwareadmission.CatalogVersion,
		},
		enforce.Version,
	)
	if err != nil {
		t.Fatal(err)
	}

	wrapped.block = true
	rollbackDone := make(chan struct{})
	go func() {
		defer close(rollbackDone)
		_, _ = srv.applyHardwareAdmissionPolicy(shadow)
	}()
	<-wrapped.checked

	revokeDone := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		req := httptest.NewRequest(
			http.MethodDelete,
			"/v1/admin/hardware-admission/machines/"+serial,
			strings.NewReader(`{"reason":"retired"}`),
		)
		req.Header.Set("Authorization", "Bearer test-key")
		req.Header.Set("Content-Type", "application/json")
		response := httptest.NewRecorder()
		srv.Handler().ServeHTTP(response, req)
		revokeDone <- response
	}()

	select {
	case <-revokeDone:
		t.Fatal("revocation bypassed the in-flight policy reconciliation lock")
	case <-time.After(50 * time.Millisecond):
	}
	close(wrapped.release)
	<-rollbackDone
	response := <-revokeDone
	if response.Code != http.StatusOK {
		t.Fatalf("revoke status = %d: %s", response.Code, response.Body.String())
	}
	if reg.ProviderHardwareAdmitted(provider) ||
		!provider.HardwareAdmissionRevokedStatus() {
		t.Fatal("rollback resurrected concurrently revoked provider")
	}
}

func TestDisconnectedProviderDoesNotSpinAdmissionCommit(t *testing.T) {
	srv, _ := testServer(t)
	provider := srv.registry.RegisterPendingHardwareAdmission(
		"disconnected-admission", nil, admissionTestRegister())
	srv.registry.Disconnect(provider.ID)

	done := make(chan bool, 1)
	go func() {
		_, admitted, _ := srv.admitProviderWithoutHardwareEvaluation(provider)
		done <- admitted
	}()
	select {
	case admitted := <-done:
		if admitted {
			t.Fatal("disconnected provider was admitted")
		}
	case <-time.After(time.Second):
		t.Fatal("disconnected admission commit did not terminate")
	}
}

func TestHardwareTrustStatusStaysPendingUntilAdmissionFinalizes(t *testing.T) {
	srv, _ := testServer(t)
	provider := srv.registry.RegisterPendingHardwareAdmission(
		"pending-trust-status", nil, admissionTestRegister())
	srv.stagePendingHardwareAdmission(provider.ID, pendingHardwareAdmission{
		provider: provider,
		policy:   hardwareadmission.Policy{Version: 1},
	})

	status, _ := srv.hardwareTrustStatus(provider, "MDM verification passed")
	if status != "admission_pending" {
		t.Fatalf("status = %q, want admission_pending", status)
	}
	srv.clearPendingHardwareAdmissionForProvider(provider)
	status, reason := srv.hardwareTrustStatus(
		provider, "MDM verification passed")
	if status != "online" || reason != "MDM verification passed" {
		t.Fatalf("finalized status = (%q,%q)", status, reason)
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

func TestPolicyChangeRechecksHardwareClaimIntegrity(t *testing.T) {
	srv, st := testServerWithConfig(t, ServerConfig{
		HardwareAdmissionMode:        "enforce",
		HardwareAdmissionMinMemoryGB: 8,
	})
	const serial = "POLICY-CHANGE-MISMATCH"
	message := admissionTestRegister()
	result := admissionTestAttestation(serial)
	provider := srv.registry.RegisterPendingHardwareAdmission(
		"policy-change-mismatch", nil, message)
	provider.SetAttestationResult(&result)
	provider.SetAttested(true, registry.TrustHardware)
	provider.SetCodeAttested(true)
	provider.Mu().Lock()
	provider.MDAVerified = true
	provider.MDAFreshnessVerified = true
	provider.Mu().Unlock()
	initialPolicy := srv.hardwareAdmissionPolicySnapshot()
	srv.stagePendingHardwareAdmission(provider.ID, pendingHardwareAdmission{
		provider: provider,
		serial:   serial,
		policy:   initialPolicy,
		decision: evaluateHardwareClaims(initialPolicy, message, result),
	})

	provider.Mu().Lock()
	provider.Hardware.MemoryGB = result.MemoryGB * 2
	provider.Mu().Unlock()
	nextPolicy, err := st.ActivateHardwareAdmissionPolicy(
		context.Background(),
		hardwareadmission.Policy{
			Mode: hardwareadmission.ModeEnforce, MinMemoryGB: 8,
			CatalogVersion: hardwareadmission.CatalogVersion,
		},
		initialPolicy.Version,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !srv.setHardwareAdmissionPolicy(nextPolicy) {
		t.Fatal("changed policy was not published")
	}

	if srv.finalizePendingHardwareAdmission(provider) {
		t.Fatal("changed policy admitted mismatched hardware claims")
	}
	if provider.HardwareAdmissionStatus() {
		t.Fatal("mismatched provider became routable")
	}
	admitted, err := st.IsHardwareAdmitted(context.Background(), serial)
	if err != nil || admitted {
		t.Fatalf("durable admission = (%v,%v), want false,nil", admitted, err)
	}
}

func TestStaleFinalizerCannotPersistNewPendingGeneration(t *testing.T) {
	srv, st := testServerWithConfig(t, ServerConfig{
		HardwareAdmissionMode:        "enforce",
		HardwareAdmissionMinMemoryGB: 8,
	})
	const serial = "PENDING-GENERATION-RACE"
	message := admissionTestRegister()
	result := admissionTestAttestation(serial)
	provider := srv.registry.RegisterPendingHardwareAdmission(
		"pending-generation-race", nil, message)
	provider.SetAttestationResult(&result)
	provider.SetAttested(true, registry.TrustHardware)
	provider.SetCodeAttested(true)
	provider.Mu().Lock()
	provider.MDAVerified = true
	provider.MDAFreshnessVerified = true
	provider.Mu().Unlock()
	initialPolicy := srv.hardwareAdmissionPolicySnapshot()
	srv.stagePendingHardwareAdmission(provider.ID, pendingHardwareAdmission{
		provider: provider,
		serial:   serial,
		policy:   initialPolicy,
		decision: evaluateHardwareClaims(initialPolicy, message, result),
	})
	nextPolicy, err := st.ActivateHardwareAdmissionPolicy(
		context.Background(),
		hardwareadmission.Policy{
			Mode: hardwareadmission.ModeEnforce, MinMemoryGB: 8,
			CatalogVersion: hardwareadmission.CatalogVersion,
		},
		initialPolicy.Version,
	)
	if err != nil {
		t.Fatal(err)
	}

	if srv.finalizePendingHardwareAdmission(provider) {
		t.Fatal("stale finalizer committed a replacement pending generation")
	}
	admitted, err := st.IsHardwareAdmitted(context.Background(), serial)
	if err != nil || admitted {
		t.Fatalf("durable admission = (%v,%v), want false,nil", admitted, err)
	}
	srv.hardwareAdmissionPendingMu.Lock()
	pending := srv.hardwareAdmissionPending[provider.ID]
	srv.hardwareAdmissionPendingMu.Unlock()
	if pending.policy.Version != nextPolicy.Version {
		t.Fatalf("pending policy = %d, want %d",
			pending.policy.Version, nextPolicy.Version)
	}
	srv.clearPendingHardwareAdmissionForProvider(provider)
}

func TestHardUntrustedProviderCannotFinalizeHardwareAdmission(t *testing.T) {
	srv, st := testServerWithConfig(t, ServerConfig{
		HardwareAdmissionMode:        "enforce",
		HardwareAdmissionMinMemoryGB: 8,
	})
	const serial = "HARD-UNTRUSTED-PENDING"
	message := admissionTestRegister()
	result := admissionTestAttestation(serial)
	provider := srv.registry.RegisterPendingHardwareAdmission(
		"hard-untrusted-pending", nil, message)
	provider.SetAttestationResult(&result)
	provider.SetAttested(true, registry.TrustHardware)
	provider.SetCodeAttested(true)
	provider.Mu().Lock()
	provider.MDAVerified = true
	provider.MDAFreshnessVerified = true
	provider.Mu().Unlock()
	policy := srv.hardwareAdmissionPolicySnapshot()
	srv.stagePendingHardwareAdmission(provider.ID, pendingHardwareAdmission{
		provider: provider,
		serial:   serial,
		policy:   policy,
		decision: evaluateHardwareClaims(policy, message, result),
	})
	srv.registry.MarkUntrusted(provider.ID)

	if srv.finalizePendingHardwareAdmission(provider) {
		t.Fatal("hard-untrusted provider finalized admission")
	}
	admitted, err := st.IsHardwareAdmitted(context.Background(), serial)
	if err != nil || admitted {
		t.Fatalf("durable admission = (%v,%v), want false,nil", admitted, err)
	}
	srv.clearPendingHardwareAdmissionForProvider(provider)
}

func TestFinalizationWorkerRearmsForNewPendingGeneration(t *testing.T) {
	srv, _ := testServer(t)
	provider := srv.registry.Register(
		"provider-worker-handoff", nil, admissionTestRegister())
	srv.stagePendingHardwareAdmission(provider.ID, pendingHardwareAdmission{
		policy: hardwareadmission.Policy{Version: 2},
	})
	srv.hardwareAdmissionPendingMu.Lock()
	srv.hardwareAdmissionFinalizeRetry[provider.ID] = struct{}{}
	srv.hardwareAdmissionPendingMu.Unlock()

	srv.finishHardwareAdmissionFinalizationRetry(provider)

	srv.hardwareAdmissionPendingMu.Lock()
	_, rearmed := srv.hardwareAdmissionFinalizeRetry[provider.ID]
	srv.hardwareAdmissionPendingMu.Unlock()
	if !rearmed {
		t.Fatal("new pending generation lost its finalization worker")
	}
	srv.clearPendingHardwareAdmission(provider.ID)
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

func TestPreEnforcementHardwareTrustGrantPersistsBeforeReturning(t *testing.T) {
	st := store.NewMemory(store.Config{})
	reg := registry.New(quietLogger())
	srv := NewServer(reg, st, ServerConfig{}, quietLogger())
	provider := reg.Register(
		"atomic-grandfather-candidate", nil, admissionTestRegister())
	result := admissionTestAttestation("ATOMIC-GRANDFATHER-1")
	provider.SetAttestationResult(&result)

	if !srv.grantProviderHardwareTrust(provider) {
		t.Fatal("hardware trust grant failed")
	}
	record, err := st.GetProviderRecord(context.Background(), provider.ID)
	if err != nil {
		t.Fatal(err)
	}
	if record == nil || record.TrustLevel != string(registry.TrustHardware) ||
		record.SerialNumber != "ATOMIC-GRANDFATHER-1" {
		t.Fatalf("grant returned before durable trust commit: %+v", record)
	}
}

func TestOfflineAdmissionStatusUsesEffectivePolicyMode(t *testing.T) {
	srv, _ := testServer(t)
	machine := myProvider{serialNumber: "OFFLINE-EFFECTIVE-1"}
	if err := srv.attachHardwareAdmissionState(
		context.Background(), &machine, nil); err != nil {
		t.Fatal(err)
	}
	if !machine.HardwareAdmitted || machine.HardwareAdmissionRevoked {
		t.Fatalf("disabled-mode offline admission = %+v", machine)
	}

	srv.setHardwareAdmissionPolicy(hardwareadmission.Policy{
		Version: 1, Mode: hardwareadmission.ModeEnforce,
		MinMemoryGB: 32, CatalogVersion: hardwareadmission.CatalogVersion,
	})
	machine = myProvider{serialNumber: "OFFLINE-EFFECTIVE-1"}
	if err := srv.attachHardwareAdmissionState(
		context.Background(), &machine, nil); err != nil {
		t.Fatal(err)
	}
	if machine.HardwareAdmitted {
		t.Fatalf("enforce-mode unadmitted offline machine = %+v", machine)
	}
}

func ptrAdmissionResult(result attestation.VerificationResult) *attestation.VerificationResult {
	return &result
}
