package api

import (
	"context"
	"fmt"
	"log/slog"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func TestProviderRegistrationModelListBoundaries(t *testing.T) {
	manyModels := make([]protocol.ModelInfo, 100)
	for i := range manyModels {
		manyModels[i] = protocol.ModelInfo{
			ID:           fmt.Sprintf("model-%d", i),
			ModelType:    "chat",
			Quantization: "4bit",
		}
	}

	for _, test := range []struct {
		name                 string
		models               []protocol.ModelInfo
		wantProviders        int
		wantRegisteredModels int
	}{
		{name: "empty list registers no models", wantProviders: 1},
		{
			name: "duplicate IDs reject registration",
			models: []protocol.ModelInfo{
				{ID: "dupe-model", ModelType: "chat", Quantization: "4bit"},
				{ID: "dupe-model", ModelType: "chat", Quantization: "8bit"},
			},
		},
		{name: "hundred distinct models", models: manyModels, wantProviders: 1, wantRegisteredModels: len(manyModels)},
	} {
		t.Run(test.name, func(t *testing.T) {
			logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
			st := store.NewMemory(store.Config{AdminKey: "test-key"})
			reg := registry.New(logger)
			srv := NewServer(reg, st, ServerConfig{}, logger)
			ts := httptest.NewServer(srv.Handler())
			defer ts.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			publicKey := testPublicKeyB64()
			if test.wantProviders == 0 {
				assertProviderRegistrationRejected(t, ctx, ts.URL, reg, test.models, publicKey)
				if got := reg.ProviderCount(); got != 0 {
					t.Fatalf("provider count = %d, want 0", got)
				}
				return
			}
			conn := connectProvider(t, ctx, ts.URL, reg, test.models, publicKey)
			defer conn.Close(websocket.StatusNormalClosure, "")
			if got := reg.ProviderCount(); got != test.wantProviders {
				t.Fatalf("provider count = %d, want %d", got, test.wantProviders)
			}
			ids := reg.ProviderIDs()
			if len(ids) != 1 {
				t.Fatalf("provider IDs = %v, want one", ids)
			}
			provider := reg.GetProvider(ids[0])
			provider.Mu().Lock()
			defer provider.Mu().Unlock()
			if got := len(provider.Models); got != test.wantRegisteredModels {
				t.Fatalf("registered models = %d, want %d", got, test.wantRegisteredModels)
			}
		})
	}
}
