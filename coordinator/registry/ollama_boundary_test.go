package registry

import (
	"context"
	"errors"
	"testing"
	"time"
)

// The companion never adds an Ollama inference backend. Keep that security
// boundary executable: an App Attest lease cannot authorize a plaintext proxy.
func TestOllamaBridgeCannotInheritAppAttestServing(t *testing.T) {
	changes := map[string]func(*Provider){
		"ollama backend":     func(p *Provider) { p.Backend = "ollama" },
		"out of process":     func(p *Provider) { p.PrivacyCapabilities.TextBackendInprocess = false },
		"proxy enabled":      func(p *Provider) { p.PrivacyCapabilities.TextProxyDisabled = false },
		"debugger allowed":   func(p *Provider) { p.PrivacyCapabilities.AntiDebugEnabled = false },
		"core dumps allowed": func(p *Provider) { p.PrivacyCapabilities.CoreDumpsDisabled = false },
	}
	for name, change := range changes {
		t.Run(name, func(t *testing.T) {
			r, p, lease := appAttestTestProvider(t)
			if !r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("grant")
			}
			_, frames := appAttestTestWriter(t, p)
			pr := &PendingRequest{RequestID: "ollama-boundary", Model: appAttestTestModel}
			if r.ReserveProvider(appAttestTestModel, pr) != p {
				t.Fatal("approved native worker did not reserve")
			}
			_, err := p.WriteInferenceTextDeferred(context.Background(), pr,
				func(time.Time) ([]byte, error) { return []byte("sealed synthetic request"), nil },
				func(TextFrameWriteMetadata) { p.mu.Lock(); change(p); p.mu.Unlock() })
			if !errors.Is(err, ErrProviderServingUnauthorized) || frames.Load() != 0 {
				t.Fatalf("unsafe backend received request: err=%v frames=%d", err, frames.Load())
			}
			if _, authorized := r.ProviderServingAuthorization(p); authorized {
				t.Fatal("unsafe worker appears authorized")
			}
			if r.ReserveProvider(appAttestTestModel, &PendingRequest{RequestID: "later", Model: appAttestTestModel}) != nil {
				t.Fatal("unsafe backend routed")
			}
		})
	}
}
