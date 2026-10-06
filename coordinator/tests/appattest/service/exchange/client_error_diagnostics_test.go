package exchange_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/observation"
	storagebudget "github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func diagnosticRegistry(t *testing.T) (*registry.Registry, *registry.Provider) {
	t.Helper()
	r := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	r.SetAppAttestServingPolicy(true, 7)
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	p := r.Register("connection", nil, &protocol.RegisterMessage{PublicKey: key, Backend: registry.BackendMLXSwift, EncryptedResponseChunks: true, Hardware: protocol.Hardware{MachineModel: "Mac16,10", MemoryGB: 32}})
	p.AccountID, p.RuntimeVerified, p.RuntimeManifestChecked = "account", true, true
	p.PrivacyCapabilities = &protocol.PrivacyCapabilities{TextBackendInprocess: true, TextProxyDisabled: true, AntiDebugEnabled: true, CoreDumpsDisabled: true, EnvScrubbed: true}
	p.Version, p.MetallibVerified = "0.9.4", true
	p.TemplateHashes = map[string]string{"mlx_metallib": strings.Repeat("b", 64)}
	p.AttestationResult = &attestation.VerificationResult{Valid: true, PublicKey: "se", EncryptionPublicKey: key, MetallibHash: strings.Repeat("b", 64)}
	p.SetAttested(true, registry.TrustSelfSigned)
	p.CompleteProviderStateRestore()
	if !r.BindVerifiedMachineIdentity(p, "account", "machine") {
		t.Fatal("identity")
	}
	t.Cleanup(func() { r.Disconnect(p.ID) })
	return r, p
}

func diagnosticObserver(p *registry.Provider, observed *map[string]any) exchange.Dependencies {
	return exchange.Dependencies{Observe: func(stage, outcome string, metadata *appattest.Key, reply protocol.AppAttestShadowPayload) {
		*observed = observation.Format(observation.Event{Provider: p, Session: "proof", Account: "account", Serving: true, Stage: stage, Outcome: outcome, Metadata: metadata, Reply: reply}).Fields
	}}
}

func diagnosticArchive(archive *capturedProofArchive, expected string, ready map[string]any, reply protocol.AppAttestShadowPayload) {
	budget, integrity := &storagebudget.Budget{}, &evidence.Integrity{}
	pipeline := exchange.NewPipeline(exchange.PipelineDependencies{Archive: archive, Provider: newSessionProvider("endpoint", "se"),
		Budget: budget, Scope: storagebudget.NewScope(budget), Integrity: integrity})
	pipeline.Handle(context.Background(), exchange.Attempt{Challenge: exchange.Challenge{Expected: expected}, Rejection: "verifier_busy", ReadyContext: ready}, reply)
}

func TestClientAppleFailureRetainsBoundedDiagnosticsWithoutAuthorization(t *testing.T) {
	r, p := diagnosticRegistry(t)
	x := exchange.Challenge{Expected: "attestation"}
	details := &protocol.AppAttestAppleError{Domain: "devicecheck", Code: 2}
	var observed map[string]any
	deps := diagnosticObserver(p, &observed)
	next := exchange.Verify(context.Background(), deps, x, protocol.AppAttestShadowPayload{Result: "apple_error", AppleError: details}).Next
	if next != "stop" || observed["apple_error"] != details || observed["outcome"] != "apple_error" {
		t.Fatalf("native failure lost its bounded cause: %s, %+v", next, observed)
	}
	if _, ok := r.ProviderServingAuthorization(p); ok {
		t.Fatal("client diagnostic data authorized a provider")
	}
	// Direct callers also cannot leak arbitrary strings into event fields.
	exchange.Verify(context.Background(), deps, x, protocol.AppAttestShadowPayload{Result: "apple_error", AppleError: &protocol.AppAttestAppleError{Domain: "private-data"}})
	if _, ok := observed["apple_error"]; ok {
		t.Fatal("unbounded domain entered telemetry")
	}
}

func TestClientAppleFailureArchivedWithOriginalProofContext(t *testing.T) {
	archive := &capturedProofArchive{}
	diagnosticArchive(archive, "attestation", nil, protocol.AppAttestShadowPayload{Action: "attestation", Result: "apple_error", AppleError: &protocol.AppAttestAppleError{Domain: "devicecheck", Code: 2}})
	var context map[string]json.RawMessage
	if err := json.Unmarshal(archive.evidence.Context, &context); err != nil {
		t.Fatal(err)
	}
	var details protocol.AppAttestAppleError
	if err := json.Unmarshal(context["apple_error"], &details); err != nil || details.Domain != "devicecheck" || details.Code != 2 {
		t.Fatalf("native diagnostic absent from evidence context: %+v, %v", details, err)
	}
}

func TestClientPreflightFailureRetainsClosedAvailabilityReasonWithoutAuthorization(t *testing.T) {
	r, p := diagnosticRegistry(t)
	x := exchange.Challenge{Expected: "ready"}
	var observed map[string]any
	deps := diagnosticObserver(p, &observed)
	reply := protocol.AppAttestShadowPayload{Action: "ready", Result: "unsupported", AvailabilityReason: "is_supported_false"}
	if next := exchange.Verify(context.Background(), deps, x, reply).Next; next != "stop" || observed["availability_reason"] != "is_supported_false" {
		t.Fatalf("bounded preflight reason lost: %s, %+v", next, observed)
	}
	if _, ok := r.ProviderServingAuthorization(p); ok {
		t.Fatal("client preflight diagnostic authorized a provider")
	}
	reply.AvailabilityReason = "arbitrary private text"
	exchange.Verify(context.Background(), deps, x, reply)
	if _, ok := observed["availability_reason"]; ok {
		t.Fatal("unbounded preflight reason entered telemetry")
	}
}

func TestSyntheticAppleErrorSourceArchivedWithoutNativeDetails(t *testing.T) {
	archive := &capturedProofArchive{}
	diagnosticArchive(archive, "attestation", nil, protocol.AppAttestShadowPayload{Action: "attestation", Result: "apple_error", AppleErrorSource: "callback_without_nserror"})
	var context map[string]json.RawMessage
	if err := json.Unmarshal(archive.evidence.Context, &context); err != nil {
		t.Fatal(err)
	}
	var source string
	if err := json.Unmarshal(context["apple_error_source"], &source); err != nil || source != "callback_without_nserror" {
		t.Fatalf("synthetic Apple error cause absent from evidence: %s, %v", source, err)
	}
	if _, ok := context["apple_error"]; ok {
		t.Fatal("synthetic failure fabricated a native NSError")
	}
}

func TestReadyRuntimeDiagnosticsReachEventAndLaterEvidenceWithoutAuthorization(t *testing.T) {
	r, p := diagnosticRegistry(t)
	x := exchange.Challenge{Expected: "ready"}
	var observed map[string]any
	deps := diagnosticObserver(p, &observed)
	ready := protocol.AppAttestShadowPayload{Action: "ready", Result: "busy", LaunchSession: "background", BootTime: 1_700_000_000, OperationStalledSeconds: 120}
	if next := exchange.Verify(context.Background(), deps, x, ready).Next; next != "stop" || observed["launch_session"] != "background" ||
		observed["boot_time"] != int64(1_700_000_000) || observed["operation_stalled_seconds"] != 120 {
		t.Fatalf("runtime diagnostics missing from ready event: %s, %+v", next, observed)
	}
	if _, ok := r.ProviderServingAuthorization(p); ok {
		t.Fatal("runtime diagnostics authorized a provider")
	}
	// Direct callers that bypass admission still cannot leak invalid values.
	exchange.Verify(context.Background(), deps, x, protocol.AppAttestShadowPayload{Action: "ready", Result: "ok", LaunchSession: "private", BootTime: 5, OperationStalledSeconds: 7})
	for _, field := range []string{"launch_session", "boot_time", "operation_stalled_seconds"} {
		if _, ok := observed[field]; ok {
			t.Fatalf("invalid %s entered telemetry", field)
		}
	}
	// A proof later in the same attempt carries the ready reply's context.
	archive := &capturedProofArchive{}
	diagnosticArchive(archive, "assertion", ready.RuntimeDiagnosticFields(time.Now()), protocol.AppAttestShadowPayload{Action: "assertion", Result: "apple_error"})
	var archived map[string]any
	if err := json.Unmarshal(archive.evidence.Context, &archived); err != nil {
		t.Fatal(err)
	}
	if archived["launch_session"] != "background" || archived["boot_time"] != float64(1_700_000_000) || archived["operation_stalled_seconds"] != float64(120) {
		t.Fatalf("runtime diagnostics absent from evidence context: %+v", archived)
	}
}
