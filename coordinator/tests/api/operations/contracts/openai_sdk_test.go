package operations_test

import (
	"context"
	"net/http/httptest"
	"testing"

	api "github.com/eigeninference/d-inference/coordinator/api"
	testkit "github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	openai "github.com/openai/openai-go"
	"github.com/openai/openai-go/option"
)

func TestOpenAI_SDK_UnimplementedEndpoint_Embeddings(t *testing.T) {
	srv := testkit.New(
		t,
		api.ServerConfig{},
	).Server

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	client := testkit.NewSDKClientForCompat(t, ts)

	_, err := client.Embeddings.New(context.Background(), openai.EmbeddingNewParams{})
	if err == nil {
		t.Fatal("expected error from unimplemented endpoint, got nil")
	}

	apiErr := testkit.AsSDKError(err)
	if apiErr == nil {
		t.Fatalf("expected openai.Error, got %T: %v", err, err)
	}
	if apiErr.StatusCode != 404 {
		t.Errorf("expected 404, got %d", apiErr.StatusCode)
	}
	if apiErr.Type == "" {
		t.Error("error type should not be empty")
	}
	if apiErr.Message == "" {
		t.Error("error message should not be empty")
	}
}

func TestOpenAI_SDK_UnimplementedEndpoint_Moderations(t *testing.T) {
	srv := testkit.New(
		t,
		api.ServerConfig{},
	).Server

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	client := testkit.NewSDKClientForCompat(t, ts)

	_, err := client.Moderations.New(context.Background(), openai.ModerationNewParams{})
	if err == nil {
		t.Fatal("expected error from unimplemented endpoint, got nil")
	}

	apiErr := testkit.AsSDKError(err)
	if apiErr == nil {
		t.Fatalf("expected openai.Error, got %T: %v", err, err)
	}
	if apiErr.StatusCode != 404 {
		t.Errorf("expected 404, got %d", apiErr.StatusCode)
	}
}

func TestOpenAI_SDK_UnimplementedEndpoint_CustomPath(t *testing.T) {
	srv := testkit.New(
		t,
		api.ServerConfig{},
	).Server

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	client := testkit.NewSDKClientForCompat(t, ts)

	var resp struct{}
	err := client.Execute(context.Background(), "POST", "/custom-unsupported-endpoint", nil, &resp)
	if err == nil {
		t.Fatal("expected error from unimplemented endpoint, got nil")
	}

	apiErr := testkit.AsSDKError(err)
	if apiErr == nil {
		t.Fatalf("expected openai.Error, got %T: %v", err, err)
	}
	if apiErr.StatusCode != 404 {
		t.Errorf("expected 404, got %d", apiErr.StatusCode)
	}
	if apiErr.Type != "invalid_request_error" {
		t.Errorf("expected type 'invalid_request_error', got %q", apiErr.Type)
	}
}

func TestOpenAI_SDK_Health(t *testing.T) {
	srv := testkit.New(
		t,
		api.ServerConfig{},
	).Server

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	// Health endpoint doesn't live under /v1, so use raw client.
	client := openai.NewClient(
		option.WithBaseURL(ts.URL),
		option.WithAPIKey("test-key"),
	)

	var result struct {
		Status string `json:"status"`
	}
	err := client.Execute(context.Background(), "GET", "/health", nil, &result)
	if err != nil {
		t.Fatalf("expected health to succeed, got: %v", err)
	}
	if result.Status != "ok" {
		t.Errorf("expected status 'ok', got %q", result.Status)
	}
}

func TestOpenAI_SDK_NonV1Unaffected(t *testing.T) {
	srv := testkit.New(
		t,
		api.ServerConfig{},
	).Server

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	resp, err := ts.Client().Get(ts.URL + "/nonexistent")
	if err != nil {
		t.Fatalf("GET /nonexistent: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 404 {
		t.Errorf("expected 404, got %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct == "application/json" {
		t.Error("non-/v1/ paths should not get JSON content type")
	}
}
