package provider_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/protocol"
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
			defer srv.Close()
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
			pubKey := testkit.PublicKeyB64()
			regData, _ := json.Marshal(protocol.RegisterMessage{
				Type:                    protocol.TypeRegister,
				Hardware:                protocol.Hardware{MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64},
				Models:                  []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
				Backend:                 "mlx-swift",
				Version:                 tc.version,
				PublicKey:               pubKey,
				EncryptedResponseChunks: true,
				PrivacyCapabilities:     testkit.PrivacyCaps(),
			})
			if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
				t.Fatalf("write register: %v", err)
			}
			// The challenge loop starts only after registration processing
			// (including the version floor) has finished, so the first
			// challenge is the barrier for asserting registration state. Do not
			// reply here: asynchronous challenge revalidation writes runtime
			// policy before applying the version floor again, which races this
			// test's manual trust/challenge grants. Challenge floor policy has
			// separate coverage below.
			testkit.ReadAttestationChallenge(t, ctx, conn)

			if got := reg.OnlineCount(); got != 1 {
				t.Fatalf("online providers = %d, want 1: the floor deroutes, it does not disconnect", got)
			}
			// Clear every other routing gate so the version floor is the only
			// thing that can keep this provider out of routing.
			testkit.MakeProviderRoutable(reg)

			if !tc.routable {
				if p := testkit.FindRoutableProvider(reg, model); p != nil {
					t.Fatalf("provider with version %q was routable under floor 0.9.5", tc.version)
				}
				if models := reg.ListModels(); len(models) != 0 {
					t.Fatalf("models = %d, want 0 for version %q under floor 0.9.5", len(models), tc.version)
				}
				return
			}
			deadline := time.Now().Add(3 * time.Second)
			for testkit.FindRoutableProvider(reg, model) == nil {
				if time.Now().After(deadline) {
					t.Fatalf("provider with version %q was not routable under floor 0.9.5", tc.version)
				}
				time.Sleep(20 * time.Millisecond)
				testkit.MakeProviderRoutable(reg)
			}
		})
	}
}
