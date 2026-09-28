package api

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// TestProviderVersionFloorExcludesMissingVersionFromRouting drives real
// WebSocket registrations against a coordinator whose routing floor is 0.9.5.
// A provider below the floor — including one that reports no version at all —
// stays connected but is never routable; a provider at the floor is. Before
// the floor counted an empty version as below it, a version-less registration
// bypassed the floor entirely.
func TestProviderVersionFloorExcludesMissingVersionFromRouting(t *testing.T) {
	cases := []struct {
		name     string
		version  string
		routable bool
	}{
		{name: "missing version", version: "", routable: false},
		{name: "below floor", version: "0.9.4", routable: false},
		{name: "at floor", version: "0.9.5", routable: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv, reg, _, ts := setupTestServer(t)
			defer ts.Close()
			srv.SetMinProviderVersion("0.9.5")

			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()

			wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
			conn, _, err := websocket.Dial(ctx, wsURL, nil)
			if err != nil {
				t.Fatalf("websocket dial: %v", err)
			}
			defer conn.Close(websocket.StatusNormalClosure, "")

			const model = "version-floor-model"
			pubKey := testPublicKeyB64()
			regData, _ := json.Marshal(protocol.RegisterMessage{
				Type:                    protocol.TypeRegister,
				Hardware:                protocol.Hardware{MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64},
				Models:                  []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
				Backend:                 "mlx-swift",
				Version:                 tc.version,
				PublicKey:               pubKey,
				EncryptedResponseChunks: true,
				PrivacyCapabilities:     testPrivacyCaps(),
			})
			if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
				t.Fatalf("write register: %v", err)
			}
			// The challenge loop starts only after registration processing
			// (including the version floor) has finished, so the first
			// challenge is the barrier for asserting registration state.
			waitForChallenge(t, ctx, conn, pubKey)

			if got := reg.OnlineCount(); got != 1 {
				t.Fatalf("online providers = %d, want 1: the floor deroutes, it does not disconnect", got)
			}
			// Clear every other routing gate so the version floor is the only
			// thing that can keep this provider out of routing.
			makeProviderRoutable(reg)

			if !tc.routable {
				if p := findRoutableProvider(reg, model); p != nil {
					t.Fatalf("provider with version %q was routable under floor 0.9.5", tc.version)
				}
				if models := reg.ListModels(); len(models) != 0 {
					t.Fatalf("models = %d, want 0 for version %q under floor 0.9.5", len(models), tc.version)
				}
				return
			}
			deadline := time.Now().Add(3 * time.Second)
			for findRoutableProvider(reg, model) == nil {
				if time.Now().After(deadline) {
					t.Fatalf("provider with version %q was not routable under floor 0.9.5", tc.version)
				}
				time.Sleep(20 * time.Millisecond)
				makeProviderRoutable(reg)
			}
		})
	}
}

// TestBelowMinProviderVersion pins the floor predicate every gate shares
// (registration, challenge revalidation, manifest sync, release evidence).
func TestBelowMinProviderVersion(t *testing.T) {
	srv := &Server{}
	for _, version := range []string{"", "0.1.0", "not-a-version"} {
		if srv.belowMinProviderVersion(version) {
			t.Fatalf("no floor configured: version %q reported below it", version)
		}
	}

	srv.SetMinProviderVersion("0.9.5")
	cases := map[string]bool{
		"":              true,
		"0.9.4":         true,
		"not-a-version": true,
		"0.9.5":         false,
		"0.9.10":        false,
		"1.0.0":         false,
	}
	for version, want := range cases {
		if got := srv.belowMinProviderVersion(version); got != want {
			t.Errorf("belowMinProviderVersion(%q) with floor 0.9.5 = %v, want %v", version, got, want)
		}
	}
}

// TestApplyChallengeMinVersionPolicyRejectsMissingVersion: challenge
// revalidation applies the same floor, so a version-less provider is derouted
// there too rather than keeping registration-time runtime state.
func TestApplyChallengeMinVersionPolicyRejectsMissingVersion(t *testing.T) {
	srv := &Server{}
	srv.SetMinProviderVersion("0.9.5")
	provider := &registry.Provider{
		RuntimeVerified:        true,
		RuntimeManifestChecked: true,
		MetallibVerified:       true,
	}
	if _, allowed := srv.applyChallengeMinVersionPolicy(provider); allowed {
		t.Fatal("version-less provider passed challenge revalidation under floor 0.9.5")
	}
	if provider.RuntimeVerified || provider.RuntimeManifestChecked || provider.MetallibVerified {
		t.Fatal("rejected provider kept policy-derived runtime state")
	}

	provider.Version = "0.9.5"
	if _, allowed := srv.applyChallengeMinVersionPolicy(provider); !allowed {
		t.Fatal("provider at the floor failed challenge revalidation")
	}
}
