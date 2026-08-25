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

func TestDisconnectDoesNotBlockWhenPendingErrorChannelIsFull(t *testing.T) {
	reg := New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	provider := reg.RegisterAuthenticated(
		"full-terminal-provider",
		nil,
		&protocol.RegisterMessage{},
		ProviderAuthBinding{AccountID: "acct", TokenHash: "token"},
	)
	errorCh := make(chan protocol.InferenceErrorMessage, 1)
	buffered := protocol.InferenceErrorMessage{
		Type:       protocol.TypeInferenceError,
		RequestID:  "already-terminal",
		Error:      "existing terminal",
		StatusCode: 499,
	}
	errorCh <- buffered
	provider.AddPending(&PendingRequest{
		RequestID:  "pending",
		ErrorCh:    errorCh,
		ChunkCh:    make(chan string),
		CompleteCh: make(chan protocol.UsageInfo),
	})

	done := make(chan struct{})
	go func() {
		reg.Disconnect("full-terminal-provider")
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Disconnect blocked on a full pending error channel")
	}
	if got := <-errorCh; got != buffered {
		t.Fatalf("buffered terminal = %+v, want %+v", got, buffered)
	}
	if _, ok := <-errorCh; ok {
		t.Fatal("pending error channel remains open after disconnect")
	}
}
