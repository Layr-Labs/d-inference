package registry

import (
	"io"
	"log/slog"
	"testing"
	"time"

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

func TestAuthBindingDisconnectDoesNotBlockOnExistingTerminal(t *testing.T) {
	reg := New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	const (
		accountID = "acct-terminal-race"
		tokenHash = "token-terminal-race"
	)
	provider := reg.RegisterAuthenticated(
		"terminal-race-provider",
		nil,
		&protocol.RegisterMessage{},
		ProviderAuthBinding{AccountID: accountID, TokenHash: tokenHash},
	)
	errorCh := make(chan protocol.InferenceErrorMessage, 1)
	errorCh <- protocol.InferenceErrorMessage{Error: "existing terminal"}
	provider.AddPending(&PendingRequest{
		RequestID:  "terminal-race-request",
		ErrorCh:    errorCh,
		ChunkCh:    make(chan string),
		CompleteCh: make(chan protocol.UsageInfo),
	})

	done := make(chan int, 1)
	go func() {
		done <- reg.DisconnectByAuthBinding(tokenHash, accountID)
	}()

	select {
	case disconnected := <-done:
		if disconnected != 1 {
			t.Fatalf("disconnected = %d, want 1", disconnected)
		}
	case <-time.After(time.Second):
		t.Fatal("auth-binding disconnect blocked on a full terminal channel")
	}
	if got := reg.GetProvider(provider.ID); got != nil {
		t.Fatal("provider remains registry-visible after disconnect")
	}
	if provider.PendingCount() != 0 {
		t.Fatalf("pending requests after disconnect = %d, want 0", provider.PendingCount())
	}
}
