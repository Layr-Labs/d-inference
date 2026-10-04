package request_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

func TestApplyMetadataDetailsRequestStripsBodyFlag(t *testing.T) {
	t.Parallel()
	parsed := map[string]any{
		"model":            "gemma-4-26b",
		"metadata_details": true,
		"messages":         []any{map[string]any{"role": "user", "content": "hi"}},
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	if !inreq.ApplyMetadataDetailsRequest(req, parsed) {
		t.Fatal("expected the body flag to be stripped")
	}
	if _, ok := parsed["metadata_details"]; ok {
		t.Fatal("metadata_details must not remain on the provider-bound body")
	}
	if parsed["model"] != "gemma-4-26b" {
		t.Fatal("unrelated fields must be preserved")
	}
	if req.Header.Get(inreq.MetadataDetailsHeader) != "true" {
		t.Fatalf("header = %q, want true", req.Header.Get(inreq.MetadataDetailsHeader))
	}
	if !inreq.MetadataDetailsFromRequest(req) {
		t.Fatal("dispatch must see the opt-in after the body flag is consumed")
	}
	forward, err := inreq.MarshalForwardBody(parsed)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(forward), "metadata_details") {
		t.Fatalf("forwarded body still contains metadata_details: %s", forward)
	}
}

func TestApplyMetadataDetailsRequestHeaderOnly(t *testing.T) {
	t.Parallel()
	parsed := map[string]any{"model": "gemma-4-26b"}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	req.Header.Set(inreq.MetadataDetailsHeader, "true")
	if inreq.ApplyMetadataDetailsRequest(req, parsed) {
		t.Fatal("header-only opt-in must not report a body strip")
	}
	if !inreq.MetadataDetailsFromRequest(req) {
		t.Fatal("header opt-in must be visible to dispatch")
	}
}

func TestApplyMetadataDetailsRequestFalseIsNoOp(t *testing.T) {
	t.Parallel()
	parsed := map[string]any{"model": "m", "metadata_details": false}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	if !inreq.ApplyMetadataDetailsRequest(req, parsed) {
		t.Fatal("false still has to be stripped so the provider never sees it")
	}
	if inreq.MetadataDetailsFromRequest(req) {
		t.Fatal("metadata_details=false must not enable the body copy")
	}
}
