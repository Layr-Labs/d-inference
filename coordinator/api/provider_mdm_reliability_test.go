package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// fakeMDMServer is a minimal MicroMDM stand-in for exercising
// verifyProviderViaMDM against a real *mdm.Client over HTTP. The test drives the
// SecurityInfo response itself by calling mdmClient.HandleWebhook with a webhook
// body whose CommandUUID matches the one this server hands out.
type fakeMDMServer struct {
	mu sync.Mutex

	device      *mdm.DeviceInfo // nil → device-not-found
	commandUUID string          // returned by POST /v1/commands

	// failMDARawCommand makes POST /v1/commands/{udid} (the raw-plist MDA path)
	// return 500 so verifyAppleDeviceAttestation aborts immediately instead of
	// blocking 60s waiting for an Apple attestation webhook in the success test.
	failMDARawCommand bool

	// failSecurityInfoCommand makes POST /v1/commands (the SecurityInfo enqueue)
	// return a 500 so mdm.SendSecurityInfoCommand errors — simulating a transient
	// MicroMDM transport failure. This must NOT hard-untrust an enrolled provider.
	failSecurityInfoCommand bool

	// failDeviceLookup makes POST /v1/devices return 500 so mdm.LookupDevice errors
	// ("device lookup failed: ...") — simulating a MicroMDM outage. The device may
	// be enrolled; this must bucket as "error", not an enrollment failure.
	failDeviceLookup bool

	pushedUDIDs []string
}

func (f *fakeMDMServer) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("POST /v1/devices", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		f.mu.Lock()
		dev := f.device
		failLookup := f.failDeviceLookup
		f.mu.Unlock()
		if failLookup {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte("micromdm device lookup unavailable"))
			return
		}
		resp := map[string]any{"devices": []mdm.DeviceInfo{}}
		if dev != nil {
			resp["devices"] = []mdm.DeviceInfo{*dev}
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	})

	// SecurityInfo command (structured endpoint). MicroMDM's POST /v1/commands
	// enqueues AND sends the APNs push itself, so we record a push here to model
	// that auto-push (the coordinator no longer issues a separate GET /push for
	// SecurityInfo). pushCount() rising is how deliverWebhookWhenPushed knows the
	// command went out.
	mux.HandleFunc("POST /v1/commands", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			UDID string `json:"udid"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		uuid := f.commandUUID
		fail := f.failSecurityInfoCommand
		if !fail {
			f.pushedUDIDs = append(f.pushedUDIDs, body.UDID) // MicroMDM auto-push
		}
		f.mu.Unlock()
		if fail {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte("micromdm unavailable"))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"payload":{"command_uuid":"` + uuid + `"}}`))
	})

	// MDA raw-plist command (POST /v1/commands/{udid}).
	mux.HandleFunc("POST /v1/commands/{udid}", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		f.mu.Lock()
		fail := f.failMDARawCommand
		f.mu.Unlock()
		if fail {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte("mda unavailable in test"))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	mux.HandleFunc("GET /push/{udid}", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.pushedUDIDs = append(f.pushedUDIDs, r.PathValue("udid"))
		f.mu.Unlock()
		w.WriteHeader(http.StatusOK)
	})

	return mux
}

func (f *fakeMDMServer) pushCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.pushedUDIDs)
}

// securityInfoWebhook builds a MicroMDM acknowledge webhook body carrying a
// SecurityInfo plist with the given CommandUUID and SIP/SecureBoot posture.
func securityInfoWebhook(udid, commandUUID string, sipEnabled bool, secureBootFull bool) []byte {
	sip := "<false/>"
	if sipEnabled {
		sip = "<true/>"
	}
	sb := "reduced"
	if secureBootFull {
		sb = "full"
	}
	plist := fmt.Sprintf(`<?xml version="1.0"?><plist version="1.0"><dict>`+
		`<key>CommandUUID</key><string>%s</string>`+
		`<key>Status</key><string>Acknowledged</string>`+
		`<key>SecurityInfo</key><dict>`+
		`<key>SystemIntegrityProtectionEnabled</key>%s`+
		`<key>SecureBootLevel</key><string>%s</string>`+
		`</dict></dict></plist>`, commandUUID, sip, sb)
	body, _ := json.Marshal(map[string]any{
		"topic": "mdm.Acknowledge",
		"acknowledge_event": map[string]string{
			"udid":        udid,
			"status":      "Acknowledged",
			"raw_payload": base64.StdEncoding.EncodeToString([]byte(plist)),
		},
	})
	return body
}

// mdmReliabilityServer builds a coordinator Server wired to a fake MicroMDM and
// registers one provider holding a valid attestation result (serial + SIP +
// SecureBoot + SE public key), at self_signed trust. It returns the server, the
// fake, and the live *registry.Provider.
func mdmReliabilityServer(t *testing.T, fake *fakeMDMServer) (*Server, *registry.Provider) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ts := httptest.NewServer(fake.handler())
	t.Cleanup(ts.Close)
	srv.SetMDMClient(mdm.NewClient(ts.URL, "test-key", slog.New(slog.NewTextHandler(io.Discard, nil))))

	msg := &protocol.RegisterMessage{
		Type:      protocol.TypeRegister,
		Hardware:  protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:    []protocol.ModelInfo{{ID: "mdm-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:   "mlx-swift",
		PublicKey: testPublicKeyB64(),
	}
	p := reg.Register("prov-mdm", nil, msg)
	p.Mu().Lock()
	p.TrustLevel = registry.TrustSelfSigned
	p.AttestationResult = &attestation.VerificationResult{
		Valid:             true, // a valid SE attestation earned self_signed
		SerialNumber:      "SERIAL-1",
		SIPEnabled:        true,
		SecureBootEnabled: true,
		PublicKey:         "se-pub-key-bytes",
	}
	p.Mu().Unlock()
	return srv, p
}

func attestResultOf(p *registry.Provider) attestation.VerificationResult {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return *p.AttestationResult
}

// deliverWebhookWhenPushed waits until the fake server records a push (proving
// SendSecurityInfoCommand ran and the command UUID is tracked + a waiter is
// registered), then delivers the SecurityInfo webhook. Runs in a goroutine.
func deliverWebhookWhenPushed(srv *Server, fake *fakeMDMServer, udid, commandUUID string, sip, secureBoot bool) {
	go func() {
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			if fake.pushCount() > 0 {
				break
			}
			time.Sleep(5 * time.Millisecond)
		}
		time.Sleep(20 * time.Millisecond)
		srv.mdmClient.HandleWebhook(securityInfoWebhook(udid, commandUUID, sip, secureBoot))
	}()
}

// TestVerifyProviderViaMDM_PostureMismatchTerminal: MDM reports SIP disabled,
// which contradicts the provider's attestation. This is a real posture mismatch
// → terminal outcome, the provider is hard-untrusted, and the failure reason is
// bucketed as "posture-mismatch".
func TestVerifyProviderViaMDM_PostureMismatchTerminal(t *testing.T) {
	fake := &fakeMDMServer{
		device:      &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true},
		commandUUID: "cmd-mismatch",
	}
	srv, p := mdmReliabilityServer(t, fake)

	// MDM says SIP=false (mismatch vs attestation SIP=true) → posture mismatch.
	deliverWebhookWhenPushed(srv, fake, "UDID-1", "cmd-mismatch", false /*sip*/, true)

	outcome := srv.verifyProviderViaMDM(context.Background(), "prov-mdm", p, attestResultOf(p))

	if outcome != mdmVerifyTerminal {
		t.Errorf("outcome = %v, want mdmVerifyTerminal", outcome)
	}
	if got := p.GetMDMFailureReason(); got != "posture-mismatch" {
		t.Errorf("MDMFailureReason = %q, want %q", got, "posture-mismatch")
	}
	if status := srv.registry.GetProvider("prov-mdm").GetStatus(); status != registry.StatusUntrusted {
		t.Errorf("status = %q, want %q (posture mismatch must mark untrusted)", status, registry.StatusUntrusted)
	}
}

// TestVerifyProviderViaMDM_TimeoutTransient: device enrolled but no SecurityInfo
// webhook ever arrives → the waiter times out. A timeout is APN latency / device
// sleep, NOT evidence of compromise: outcome is transient, the provider is NOT
// marked untrusted, trust stays self_signed, and the reason is
// "securityinfo-timeout".
//
// VerifyProvider's WaitForSecurityInfo timeout is hardcoded at 90s and cannot be
// shortened without editing source, so this end-to-end timeout test is OPT-IN
// (set RUN_MDM_TIMEOUT_TEST=1) to keep the default suite fast and deterministic.
// The fast, deterministic proof that a "timeout" error string drives the
// securityinfo-timeout bucket lives in the mdm package
// (TestVerifyProviderTimeoutErrorString, 50ms) plus the classification logic
// exercised by the other outcomes here.
func TestVerifyProviderViaMDM_TimeoutTransient(t *testing.T) {
	if os.Getenv("RUN_MDM_TIMEOUT_TEST") != "1" {
		t.Skip("opt-in: set RUN_MDM_TIMEOUT_TEST=1 (exercises the real 90s SecurityInfo wait)")
	}
	fake := &fakeMDMServer{
		device:      &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true},
		commandUUID: "cmd-timeout",
	}
	srv, p := mdmReliabilityServer(t, fake)

	// Deliberately never deliver a webhook → WaitForSecurityInfo times out.
	outcome := srv.verifyProviderViaMDM(context.Background(), "prov-mdm", p, attestResultOf(p))

	if outcome != mdmVerifyTransient {
		t.Errorf("outcome = %v, want mdmVerifyTransient", outcome)
	}
	if got := p.GetMDMFailureReason(); got != "securityinfo-timeout" {
		t.Errorf("MDMFailureReason = %q, want %q", got, "securityinfo-timeout")
	}
	if lvl := p.GetTrustLevel(); lvl != registry.TrustSelfSigned {
		t.Errorf("trust = %q, want %q (timeout must not change trust)", lvl, registry.TrustSelfSigned)
	}
	if status := srv.registry.GetProvider("prov-mdm").GetStatus(); status == registry.StatusUntrusted {
		t.Error("timeout must NOT mark provider untrusted")
	}
}

// TestVerifyProviderViaMDM_DeviceNotFoundTransient: MicroMDM has no record of
// the serial → transient outcome (provider may simply not have enrolled yet)
// and the reason buckets as "device-not-found". Trust is untouched.
func TestVerifyProviderViaMDM_DeviceNotFoundTransient(t *testing.T) {
	fake := &fakeMDMServer{device: nil, commandUUID: "unused"}
	srv, p := mdmReliabilityServer(t, fake)

	outcome := srv.verifyProviderViaMDM(context.Background(), "prov-mdm", p, attestResultOf(p))

	if outcome != mdmVerifyTransient {
		t.Errorf("outcome = %v, want mdmVerifyTransient", outcome)
	}
	if got := p.GetMDMFailureReason(); got != "device-not-found" {
		t.Errorf("MDMFailureReason = %q, want %q", got, "device-not-found")
	}
	if lvl := p.GetTrustLevel(); lvl != registry.TrustSelfSigned {
		t.Errorf("trust = %q, want %q (not-found must not change trust)", lvl, registry.TrustSelfSigned)
	}
	if status := srv.registry.GetProvider("prov-mdm").GetStatus(); status == registry.StatusUntrusted {
		t.Error("device-not-found must NOT mark provider untrusted")
	}
}

// TestVerifyProviderViaMDM_SuccessGranted: device enrolled + SecurityInfo
// confirms SIP enabled & Secure Boot full matching attestation → granted
// outcome, trust upgrades to hardware, and the failure reason is cleared. The
// fake fails the downstream MDA raw command so verifyAppleDeviceAttestation
// returns immediately (the upgrade has already happened by then).
func TestVerifyProviderViaMDM_SuccessGranted(t *testing.T) {
	fake := &fakeMDMServer{
		device:            &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true},
		commandUUID:       "cmd-ok",
		failMDARawCommand: true,
	}
	srv, p := mdmReliabilityServer(t, fake)
	// Seed a stale failure reason to prove success clears it.
	p.SetMDMFailureReason("securityinfo-timeout")

	deliverWebhookWhenPushed(srv, fake, "UDID-1", "cmd-ok", true /*sip*/, true /*secureboot*/)

	outcome := srv.verifyProviderViaMDM(context.Background(), "prov-mdm", p, attestResultOf(p))

	if outcome != mdmVerifyGranted {
		t.Errorf("outcome = %v, want mdmVerifyGranted", outcome)
	}
	if lvl := p.GetTrustLevel(); lvl != registry.TrustHardware {
		t.Errorf("trust = %q, want %q after success", lvl, registry.TrustHardware)
	}
	if got := p.GetMDMFailureReason(); got != "" {
		t.Errorf("MDMFailureReason = %q, want empty after success", got)
	}
}

// TestProviderAttestationGatesProofsOnHardware is the drift guard for
// GET /v1/providers/attestation: a self_signed provider that (incorrectly) has
// MDAVerified/ACMEVerified=true set must report mda_verified=false /
// acme_verified=false / mdm_verified=false, while a hardware provider with the
// same flags reports them true. All three are gated on the live trust level.
func TestProviderAttestationGatesProofsOnHardware(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	mk := func(id, model string, trust registry.TrustLevel) {
		msg := &protocol.RegisterMessage{
			Type:      protocol.TypeRegister,
			Hardware:  protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
			Models:    []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
			Backend:   "mlx-swift",
			PublicKey: testPublicKeyB64(),
		}
		p := reg.Register(id, nil, msg)
		p.Mu().Lock()
		p.TrustLevel = trust
		// Drift: set the hardware proof flags true regardless of trust level.
		p.MDAVerified = true
		p.ACMEVerified = true
		p.AttestationResult = &attestation.VerificationResult{SerialNumber: "S-" + id, SIPEnabled: true, SecureBootEnabled: true}
		p.Mu().Unlock()
	}
	mk("self-signed-prov", "model-ss", registry.TrustSelfSigned)
	mk("hardware-prov", "model-hw", registry.TrustHardware)

	resp, err := http.Get(ts.URL + "/v1/providers/attestation")
	if err != nil {
		t.Fatalf("GET attestation: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}

	var parsed struct {
		Providers []struct {
			ProviderID   string `json:"provider_id"`
			TrustLevel   string `json:"trust_level"`
			MDMVerified  bool   `json:"mdm_verified"`
			MDAVerified  bool   `json:"mda_verified"`
			ACMEVerified bool   `json:"acme_verified"`
		} `json:"providers"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		t.Fatalf("decode: %v", err)
	}

	byID := map[string]struct {
		trust          string
		mdm, mda, acme bool
	}{}
	for _, pr := range parsed.Providers {
		byID[pr.ProviderID] = struct {
			trust          string
			mdm, mda, acme bool
		}{pr.TrustLevel, pr.MDMVerified, pr.MDAVerified, pr.ACMEVerified}
	}

	ss, ok := byID["self-signed-prov"]
	if !ok {
		t.Fatal("self-signed-prov missing from attestation response")
	}
	if ss.trust != string(registry.TrustSelfSigned) {
		t.Errorf("self-signed trust_level = %q, want self_signed", ss.trust)
	}
	if ss.mdm || ss.mda || ss.acme {
		t.Errorf("self_signed proofs must all be false despite drift flags, got mdm=%v mda=%v acme=%v", ss.mdm, ss.mda, ss.acme)
	}

	hw, ok := byID["hardware-prov"]
	if !ok {
		t.Fatal("hardware-prov missing from attestation response")
	}
	if !hw.mdm || !hw.mda || !hw.acme {
		t.Errorf("hardware proofs should all be true, got mdm=%v mda=%v acme=%v", hw.mdm, hw.mda, hw.acme)
	}
}

// TestVerifyProviderViaMDM_TransportErrorTransient is the regression for the
// classifier bug where a non-timeout MicroMDM error (e.g. the SecurityInfo
// command enqueue failing — HTTP 500 / decode error) was treated as a posture
// mismatch and hard-untrusted an enrolled, genuinely-secure provider. A transport
// failure proves nothing about posture (SecurityMismatch=false), so it must be
// transient ("error") and must NOT untrust.
func TestVerifyProviderViaMDM_TransportErrorTransient(t *testing.T) {
	fake := &fakeMDMServer{
		device:                  &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true},
		commandUUID:             "cmd-unused",
		failSecurityInfoCommand: true, // POST /v1/commands → 500 → SendSecurityInfoCommand errors
	}
	srv, p := mdmReliabilityServer(t, fake)

	outcome := srv.verifyProviderViaMDM(context.Background(), "prov-mdm", p, attestResultOf(p))

	if outcome != mdmVerifyTransient {
		t.Errorf("outcome = %v, want mdmVerifyTransient (transport error is not a posture mismatch)", outcome)
	}
	if got := p.GetMDMFailureReason(); got != "error" {
		t.Errorf("MDMFailureReason = %q, want %q", got, "error")
	}
	if lvl := p.GetTrustLevel(); lvl != registry.TrustSelfSigned {
		t.Errorf("trust = %q, want %q (transport error must not change trust)", lvl, registry.TrustSelfSigned)
	}
	if status := srv.registry.GetProvider("prov-mdm").GetStatus(); status == registry.StatusUntrusted {
		t.Error("a transient MicroMDM transport error must NOT hard-untrust an enrolled provider")
	}
}

// TestProviderAttestationGatesMDAPayloadOnHardware is the regression for the
// drift where /v1/providers/attestation gated the mda_verified boolean on
// hardware but still emitted the MDA cert chain + serial/udid payload (which the
// late-MDA callback can attach to a since-reconnected self_signed provider). The
// whole MDA payload must be suppressed for non-hardware connections, so the
// endpoint can never show mda_verified=false alongside a populated cert chain.
func TestProviderAttestationGatesMDAPayloadOnHardware(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	mk := func(id, model string, trust registry.TrustLevel) {
		msg := &protocol.RegisterMessage{
			Type:      protocol.TypeRegister,
			Hardware:  protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
			Models:    []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
			Backend:   "mlx-swift",
			PublicKey: testPublicKeyB64(),
		}
		p := reg.Register(id, nil, msg)
		p.Mu().Lock()
		p.TrustLevel = trust
		p.MDAVerified = true
		p.MDACertChain = [][]byte{[]byte("der-leaf"), []byte("der-intermediate")}
		p.MDAResult = &attestation.MDAResult{DeviceSerial: "MDA-" + id, DeviceUDID: "UDID-" + id, OSVersion: "26.5"}
		p.AttestationResult = &attestation.VerificationResult{SerialNumber: "S-" + id, SIPEnabled: true, SecureBootEnabled: true}
		p.Mu().Unlock()
	}
	mk("ss-payload", "m-ss", registry.TrustSelfSigned)
	mk("hw-payload", "m-hw", registry.TrustHardware)

	resp, err := http.Get(ts.URL + "/v1/providers/attestation")
	if err != nil {
		t.Fatalf("GET attestation: %v", err)
	}
	defer resp.Body.Close()

	var parsed struct {
		Providers []struct {
			ProviderID   string   `json:"provider_id"`
			MDAVerified  bool     `json:"mda_verified"`
			MDACertChain []string `json:"mda_cert_chain_b64"`
			MDASerial    string   `json:"mda_serial"`
			MDAUDID      string   `json:"mda_udid"`
		} `json:"providers"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		t.Fatalf("decode: %v", err)
	}
	for _, pr := range parsed.Providers {
		switch pr.ProviderID {
		case "ss-payload":
			if pr.MDAVerified || len(pr.MDACertChain) != 0 || pr.MDASerial != "" || pr.MDAUDID != "" {
				t.Errorf("self_signed provider leaked MDA payload: verified=%v chain=%d serial=%q udid=%q",
					pr.MDAVerified, len(pr.MDACertChain), pr.MDASerial, pr.MDAUDID)
			}
		case "hw-payload":
			if !pr.MDAVerified || len(pr.MDACertChain) != 2 || pr.MDASerial == "" {
				t.Errorf("hardware provider should expose MDA payload: verified=%v chain=%d serial=%q",
					pr.MDAVerified, len(pr.MDACertChain), pr.MDASerial)
			}
		}
	}
}

// TestVerifyProviderViaMDM_InvalidAttestationNotPromoted is the regression for the
// P1: a provider whose SE attestation is INVALID (Valid=false) must never be
// promoted to hardware by a later MDM SecurityInfo success. The verify path
// refuses up front, so even a fully-passing fake MDM cannot grant hardware.
func TestVerifyProviderViaMDM_InvalidAttestationNotPromoted(t *testing.T) {
	fake := &fakeMDMServer{
		device:            &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true},
		commandUUID:       "cmd-ok",
		failMDARawCommand: true,
	}
	srv, p := mdmReliabilityServer(t, fake)
	// Force the attestation invalid (e.g. Open Mode connected a bad attestation).
	p.Mu().Lock()
	p.AttestationResult.Valid = false
	p.Mu().Unlock()
	// Even if SecurityInfo would pass, the invalid attestation must block promotion.
	deliverWebhookWhenPushed(srv, fake, "UDID-1", "cmd-ok", true, true)

	outcome := srv.verifyProviderViaMDM(context.Background(), "prov-mdm", p, attestResultOf(p))

	if outcome == mdmVerifyGranted {
		t.Error("invalid attestation must NOT be granted hardware via MDM")
	}
	if lvl := p.GetTrustLevel(); lvl == registry.TrustHardware {
		t.Errorf("trust = %q, must not be hardware for an invalid attestation", lvl)
	}
}

// TestVerifyProviderViaMDM_LookupFailureBucketsAsError is the regression for the
// mis-classification: a MicroMDM lookup/transport failure (500) returns
// DeviceEnrolled=false with "device lookup failed: ..." — the device may well be
// enrolled. It must bucket as "error" (MDM outage), not an enrollment failure, so
// the stuck-cohort gauge doesn't point operators at provider enrollment.
func TestVerifyProviderViaMDM_LookupFailureBucketsAsError(t *testing.T) {
	fake := &fakeMDMServer{failDeviceLookup: true}
	srv, p := mdmReliabilityServer(t, fake)

	outcome := srv.verifyProviderViaMDM(context.Background(), "prov-mdm", p, attestResultOf(p))

	if outcome != mdmVerifyTransient {
		t.Errorf("outcome = %v, want mdmVerifyTransient", outcome)
	}
	if got := p.GetMDMFailureReason(); got != "error" {
		t.Errorf("MDMFailureReason = %q, want %q (MDM transport failure is not an enrollment problem)", got, "error")
	}
}

// TestApplyLateSecurityInfo_GrantsAndClears: a late SecurityInfo (after the sync
// wait timed out) for a self_signed, online, valid-attestation provider upgrades
// it to hardware and clears the failure reason — mirroring the sync success path.
func TestApplyLateSecurityInfo_GrantsAndClears(t *testing.T) {
	fake := &fakeMDMServer{
		device:      &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true},
		commandUUID: "unused",
	}
	srv, p := mdmReliabilityServer(t, fake)
	p.SetMDMFailureReason("securityinfo-timeout") // left behind by the timed-out sync attempt

	srv.ApplyLateSecurityInfo("UDID-1", &mdm.SecurityInfoResponse{
		SystemIntegrityProtectionEnabled: true,
		SecureBootLevel:                  "full",
	})

	if lvl := p.GetTrustLevel(); lvl != registry.TrustHardware {
		t.Errorf("trust = %q, want hardware after late SecurityInfo", lvl)
	}
	if got := p.GetMDMFailureReason(); got != "" {
		t.Errorf("MDMFailureReason = %q, want cleared", got)
	}
}

// TestApplyLateSecurityInfo_SkipsUntrusted: if the provider became untrusted while
// the SecurityInfo response was in flight, the late path must NOT grant hardware
// (that would leave hardware/untrusted). Mirrors the sync-path status guard.
func TestApplyLateSecurityInfo_SkipsUntrusted(t *testing.T) {
	fake := &fakeMDMServer{
		device:      &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true},
		commandUUID: "unused",
	}
	srv, p := mdmReliabilityServer(t, fake)
	srv.registry.MarkUntrusted("prov-mdm") // hard deroute while MDM was in flight

	srv.ApplyLateSecurityInfo("UDID-1", &mdm.SecurityInfoResponse{
		SystemIntegrityProtectionEnabled: true,
		SecureBootLevel:                  "full",
	})

	if lvl := p.GetTrustLevel(); lvl == registry.TrustHardware {
		t.Error("must NOT grant hardware to an untrusted provider via the late path")
	}
}

// TestVerifyProviderViaMDM_DefersGrantWhenUntrusted covers the atomic
// GrantHardwareIfNotUntrusted guard: even a fully-passing SecurityInfo must NOT
// promote a provider that is currently untrusted (a challenge-loop deroute racing
// the in-flight verify), which would otherwise leave hardware/untrusted.
func TestVerifyProviderViaMDM_DefersGrantWhenUntrusted(t *testing.T) {
	fake := &fakeMDMServer{
		device:            &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true},
		commandUUID:       "cmd-ok",
		failMDARawCommand: true,
	}
	srv, p := mdmReliabilityServer(t, fake)
	srv.registry.MarkUntrusted("prov-mdm") // deroute lands while MDM verify is in flight
	deliverWebhookWhenPushed(srv, fake, "UDID-1", "cmd-ok", true, true)

	outcome := srv.verifyProviderViaMDM(context.Background(), "prov-mdm", p, attestResultOf(p))

	if outcome != mdmVerifyTransient {
		t.Errorf("outcome = %v, want mdmVerifyTransient (must not grant while untrusted)", outcome)
	}
	if lvl := p.GetTrustLevel(); lvl == registry.TrustHardware {
		t.Error("must NOT grant hardware to an untrusted provider (would leave hardware/untrusted)")
	}
}
