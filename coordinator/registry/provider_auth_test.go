package registry

import (
	"io"
	"log/slog"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestIdentityScopedDisconnectCannotEvictReplacementConnection(t *testing.T) {
	reg := New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	const providerID = "reused-provider-id"

	original := reg.RegisterAuthenticated(
		providerID,
		nil,
		&protocol.RegisterMessage{},
		ProviderAuthBinding{AccountID: "acct-old", TokenHash: "token-old"},
	)
	matches := reg.providersForAccountIdentity("acct-old", providerID)
	if len(matches) != 1 || matches[0].provider != original {
		t.Fatalf("old-owner matches = %+v", matches)
	}

	replacement := reg.RegisterAuthenticated(
		providerID,
		nil,
		&protocol.RegisterMessage{},
		ProviderAuthBinding{AccountID: "acct-new", TokenHash: "token-new"},
	)
	if reg.disconnect(matches[0].id, matches[0].provider) {
		t.Fatal("conditional disconnect removed a replacement connection")
	}
	if got := reg.GetProvider(providerID); got != replacement {
		t.Fatal("replacement connection is no longer registry-visible")
	}
}
