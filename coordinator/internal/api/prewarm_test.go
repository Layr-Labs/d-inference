package api

import (
	"context"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
)

func TestProviderIsReadyForModel(t *testing.T) {
	p := &registry.Provider{CurrentModel: "m1", WarmModels: []string{"m2"}}
	if !providerIsReadyForModel(p, "m1") {
		t.Fatal("current model should be ready")
	}
	if !providerIsReadyForModel(p, "m2") {
		t.Fatal("warm model should be ready")
	}
	if providerIsReadyForModel(p, "m3") {
		t.Fatal("unknown model should not be ready")
	}
}

func TestDispatchStandbyPreloadsColdSwiftProviders(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	model := "standby-model"
	primary := &registry.Provider{
		ID:              "primary",
		Backend:         registry.BackendMLXSwift,
		Models:          []protocol.ModelInfo{{ID: model}},
		WarmModels:      []string{model},
		Status:          registry.StatusServing,
		TrustLevel:      registry.TrustHardware,
		RuntimeVerified: true,
		LastHeartbeat:   time.Now(),
	}
	cold := &registry.Provider{
		ID:              "cold",
		Backend:         registry.BackendMLXSwift,
		Models:          []protocol.ModelInfo{{ID: model}},
		Status:          registry.StatusOnline,
		TrustLevel:      registry.TrustHardware,
		RuntimeVerified: true,
		LastHeartbeat:   time.Now(),
	}

	primaryMsg := protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Models:                  []protocol.ModelInfo{{ID: model}},
		Backend:                 registry.BackendMLXSwift,
		EncryptedResponseChunks: true,
		PublicKey:               "pub-primary",
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	coldMsg := primaryMsg
	coldMsg.PublicKey = "pub-cold"
	primary = reg.Register("primary", nil, &primaryMsg)
	cold = reg.Register("cold", nil, &coldMsg)
	primary.WarmModels = []string{model}
	primary.RuntimeVerified = true
	cold.RuntimeVerified = true
	reg.SetTrustLevel(primary.ID, registry.TrustHardware)
	reg.SetTrustLevel(cold.ID, registry.TrustHardware)
	reg.RecordChallengeSuccess(primary.ID)
	reg.RecordChallengeSuccess(cold.ID)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	sent := make(chan protocol.LoadModelMessage, 1)
	server := &Server{registry: reg, logger: logger, providerPrewarmWriter: func(ctx context.Context, p *registry.Provider, msg protocol.LoadModelMessage) error {
		sent <- msg
		return nil
	}}

	server.dispatchStandbyPreloads(ctx, model, primary)
	select {
	case msg := <-sent:
		if msg.Type != protocol.TypeLoadModel || msg.ModelID != model {
			t.Fatalf("unexpected preload message: %+v", msg)
		}
	case <-time.After(time.Second):
		t.Fatal("expected standby preload message")
	}

	cold.WarmModels = []string{model}
	server.dispatchStandbyPreloads(ctx, model, primary)
	select {
	case msg := <-sent:
		t.Fatalf("unexpected preload for already-warm provider: %+v", msg)
	default:
	}
}
