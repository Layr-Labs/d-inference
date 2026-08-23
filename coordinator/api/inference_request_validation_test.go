package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestChatCompletionsRejectsMalformedJSON(t *testing.T) {
	srv, _ := testServer(t)
	for _, test := range []struct {
		name string
		body string
	}{
		{name: "empty body"},
		{name: "truncated", body: `{"model":"test"`},
		{name: "bare string", body: `"just a string"`},
		{name: "bare number", body: `42`},
		{name: "bare null", body: `null`},
		{name: "bare array", body: `[1,2,3]`},
		{name: "trailing comma", body: `{"model":"test",}`},
		{name: "single quotes", body: `{'model':'test'}`},
		{name: "binary garbage", body: "\x00\x01\x02\x03"},
	} {
		t.Run(test.name, func(t *testing.T) {
			rec := serveChatValidationRequest(srv, http.MethodPost, test.body, "Bearer test-key")
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestChatCompletionsRequiresModelAndMessages(t *testing.T) {
	srv, _ := testServer(t)
	for _, test := range []struct {
		name string
		body string
	}{
		{name: "missing model", body: `{"messages":[{"role":"user","content":"hi"}]}`},
		{name: "empty model", body: `{"model":"","messages":[{"role":"user","content":"hi"}]}`},
		{name: "missing messages", body: `{"model":"test-model"}`},
		{name: "empty messages", body: `{"model":"test-model","messages":[]}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			rec := serveChatValidationRequest(srv, http.MethodPost, test.body, "Bearer test-key")
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400; body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestChatCompletionsRejectsModelOutsideCatalog(t *testing.T) {
	srv, _ := testServer(t)
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: "allowed-model"}})
	rec := serveChatValidationRequest(
		srv,
		http.MethodPost,
		`{"model":"forbidden-model","messages":[{"role":"user","content":"hi"}]}`,
		"Bearer test-key",
	)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404; body=%s", rec.Code, rec.Body.String())
	}
}

func TestChatCompletionsRejectsMalformedAuthorization(t *testing.T) {
	srv, _ := testServer(t)
	for _, test := range []struct {
		name   string
		header string
	}{
		{name: "empty bearer", header: "Bearer "},
		{name: "no bearer prefix", header: "test-key"},
		{name: "basic auth", header: "Basic dGVzdDp0ZXN0"},
		{name: "double bearer", header: "Bearer Bearer test-key"},
		{name: "just bearer", header: "Bearer"},
	} {
		t.Run(test.name, func(t *testing.T) {
			rec := serveChatValidationRequest(
				srv,
				http.MethodPost,
				`{"model":"test","messages":[{"role":"user","content":"hi"}]}`,
				test.header,
			)
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401; body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestChatCompletionsWrongMethodsUseJSONNotFound(t *testing.T) {
	srv, _ := testServer(t)
	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		t.Run(method, func(t *testing.T) {
			rec := serveChatValidationRequest(srv, method, "", "Bearer test-key")
			if rec.Code != http.StatusNotFound {
				t.Fatalf("status = %d, want 404; body=%s", rec.Code, rec.Body.String())
			}
			if contentType := rec.Header().Get("Content-Type"); contentType != "application/json" {
				t.Fatalf("Content-Type = %q, want application/json", contentType)
			}
		})
	}
}

func serveChatValidationRequest(srv *Server, method, body, authorization string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, "/v1/chat/completions", strings.NewReader(body))
	if authorization != "" {
		req.Header.Set("Authorization", authorization)
	}
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	return rec
}
