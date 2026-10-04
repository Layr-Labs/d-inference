package response_test

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestRequestTimingDetailsAnchorsRoutePastMediaFetch(t *testing.T) {
	t.Parallel()
	start := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	timing := &registry.RequestTiming{
		ReceivedAt:     start,
		ParsedAt:       start.Add(1 * time.Millisecond),
		ReservedAt:     start.Add(2 * time.Millisecond),
		MediaFetchedAt: start.Add(12 * time.Millisecond),
		RoutedAt:       start.Add(13 * time.Millisecond),
		EncryptedAt:    start.Add(14 * time.Millisecond),
		DispatchedAt:   start.Add(15 * time.Millisecond),
		FirstChunkAt:   start.Add(40 * time.Millisecond),
	}
	got := inresp.RequestTimingDetails(timing)
	if got == nil {
		t.Fatal("expected timing details")
	}
	if got.ParseUs != 1000 {
		t.Errorf("parse_us = %d, want 1000", got.ParseUs)
	}
	if got.ReserveUs != 1000 {
		t.Errorf("reserve_us = %d, want 1000", got.ReserveUs)
	}
	if got.MediaFetchUs != 10000 {
		t.Errorf("media_fetch_us = %d, want 10000", got.MediaFetchUs)
	}
	if got.RouteUs != 1000 {
		t.Errorf("route_us = %d, want 1000 (must not include media fetch)", got.RouteUs)
	}
	if got.ProviderUs != 25000 {
		t.Errorf("provider_us = %d, want 25000", got.ProviderUs)
	}
}

func TestSnapshotAndAttachChatCompletionMetadata(t *testing.T) {
	t.Parallel()
	pr := &registry.PendingRequest{RequestID: "job-9", MetadataDetails: true}
	inresp.SnapshotChatCompletionMetadata(pr, inresp.CommittedProviderInfo{
		ProviderID: "prov-9",
		Attested:   true,
		TrustLevel: registry.TrustSelfSigned,
		Chip:       "Apple M3 Max",
	})
	if !inresp.HasChatCompletionMetadata(pr) {
		t.Fatal("expected a metadata snapshot")
	}
	obj := map[string]any{"id": "chatcmpl-job-9"}
	inresp.AttachChatCompletionMetadata(obj, pr)
	raw, err := json.Marshal(obj)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"provider_id":"prov-9"`) {
		t.Fatalf("attached metadata missing provider_id: %s", raw)
	}

	resp := types.ChatCompletionResponse{ID: "chatcmpl-job-9"}
	inresp.ApplyChatCompletionMetadataToResponse(&resp, pr)
	if resp.Metadata == nil || resp.Metadata.ProviderID != "prov-9" {
		t.Fatalf("typed response metadata = %+v", resp.Metadata)
	}

	skipped := &registry.PendingRequest{RequestID: "job-0"}
	inresp.SnapshotChatCompletionMetadata(skipped, inresp.CommittedProviderInfo{ProviderID: "prov-9"})
	if inresp.HasChatCompletionMetadata(skipped) {
		t.Fatal("opt-out requests must not snapshot metadata")
	}
}

func TestIsChatCompletionsConsumer(t *testing.T) {
	t.Parallel()
	if !inresp.IsChatCompletionsConsumer(&registry.PendingRequest{}) {
		t.Fatal("plain chat pending request is a chat-completions consumer")
	}
	if inresp.IsChatCompletionsConsumer(&registry.PendingRequest{IsResponsesAPI: true}) {
		t.Fatal("Responses API must not get chat metadata")
	}
	if inresp.IsChatCompletionsConsumer(&registry.PendingRequest{ConsumerEndpoint: inreq.CompletionsEndpoint}) {
		t.Fatal("legacy completions must not get chat metadata")
	}
	if inresp.IsChatCompletionsConsumer(&registry.PendingRequest{ConsumerEndpoint: inreq.MessagesEndpoint}) {
		t.Fatal("Anthropic messages must not get chat metadata")
	}
}

func TestWriteCommittedProviderHeaders(t *testing.T) {
	t.Parallel()
	se := false
	rec := httptest.NewRecorder()
	inresp.WriteCommittedProviderHeaders(rec, inresp.CommittedProviderInfo{
		ProviderID:    "prov-h",
		Attested:      false,
		TrustLevel:    registry.TrustNone,
		Encrypted:     true,
		Chip:          "Apple M4",
		MachineModel:  "Mac16,7",
		SecureEnclave: &se,
		MDAVerified:   false,
		SEPublicKey:   "se-key",
	})
	h := rec.Result().Header
	if h.Get("X-Provider-Id") != "prov-h" {
		t.Errorf("X-Provider-Id = %q", h.Get("X-Provider-Id"))
	}
	if h.Get("X-Provider-Attested") != "false" {
		t.Errorf("X-Provider-Attested = %q", h.Get("X-Provider-Attested"))
	}
	if h.Get("X-Provider-Encrypted") != "true" {
		t.Errorf("X-Provider-Encrypted = %q", h.Get("X-Provider-Encrypted"))
	}
	if h.Get("X-Provider-Secure-Enclave") != "false" {
		t.Errorf("X-Provider-Secure-Enclave = %q", h.Get("X-Provider-Secure-Enclave"))
	}
	if h.Get("X-Provider-Mda-Verified") != "" {
		t.Errorf("MDA header should stay omitted when false, got %q", h.Get("X-Provider-Mda-Verified"))
	}
	if h.Get("X-Provider-Serial") != "" {
		t.Fatal("must not emit a serial header")
	}
}
