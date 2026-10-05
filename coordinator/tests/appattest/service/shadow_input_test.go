package service_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"io"
	"log/slog"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestAppAttestShadowUsesBoundedValidatedEndpointKey(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	valid := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{3}, 32))
	for _, input := range []string{"", strings.Repeat("!", 1<<20), valid + strings.Repeat("\n", 1<<20), valid} {
		reg := registry.New(logger)
		r := &protocol.RegisterMessage{PublicKey: input, AppAttestProtocol: 3}
		p := reg.Register("session", nil, r)
		st := memorystore.NewMemory(store.Config{})
		s := service.New(context.Background(), service.Config{Enabled: true, AppID: "TEST.app", Environment: "production"}, service.Dependencies{Store: st, Logger: logger, Registry: reg})
		ctx, cancel := context.WithCancel(context.Background())
		cancel() // No Apple/network work; inspect the constructed session only.
		if input == valid {
			// Simulate a caller retaining an unvalidated registration after the
			// registry accepted a different, valid endpoint. Only p is trusted.
			r.PublicKey = strings.Repeat("!", 1<<20)
		}
		x := s.StartSession(ctx, p, r, "")
		if input == valid {
			endpoint, accepted := transcript.Endpoint(p.PublicKey)
			if x == nil || !accepted || endpoint != valid {
				t.Fatal("shadow did not use the registry's validated endpoint")
			}
		} else if x != nil {
			t.Fatalf("invalid/noncanonical endpoint started shadow: %d bytes", len(input))
		}
		reg.Disconnect(p.ID)
	}
}
