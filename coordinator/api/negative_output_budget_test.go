package api

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestNegativeOutputBudgetsRejectedBeforeAdmission(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	st := store.NewMemory(store.Config{AdminKey: "budget-fixture-key"})
	srv := NewServer(reg, st, ServerConfig{}, logger)
	server := httptest.NewServer(srv.Handler())
	defer server.Close()
	for _, endpoint := range []string{"/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages"} {
		for _, field := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
			for _, stream := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/%s/stream=%t", endpoint, field, stream), func(t *testing.T) {
					body := fmt.Sprintf(`{"model":"budget-fixture","messages":[{"role":"user","content":"hello"}],"input":"hello","prompt":"hello","stream":%t,%q:-1}`, stream, field)
					req, err := http.NewRequest(http.MethodPost, server.URL+endpoint, strings.NewReader(body))
					if err != nil {
						t.Fatal(err)
					}
					req.Header.Set("Authorization", "Bearer budget-fixture-key")
					req.Header.Set("Content-Type", "application/json")
					res, err := server.Client().Do(req)
					if err != nil {
						t.Fatal(err)
					}
					defer res.Body.Close()
					var reply struct {
						Error struct {
							Type  string `json:"type"`
							Param string `json:"param"`
						} `json:"error"`
					}
					if err := json.NewDecoder(res.Body).Decode(&reply); err != nil {
						t.Fatal(err)
					}
					if res.StatusCode != http.StatusBadRequest || reply.Error.Type != "invalid_request_error" || reply.Error.Param != field {
						t.Fatalf("negative budget reached admission instead of field validation: status=%d type=%q param=%q", res.StatusCode, reply.Error.Type, reply.Error.Param)
					}
					if strings.Contains(res.Header.Get("Content-Type"), "text/event-stream") {
						t.Fatal("validation committed streaming headers")
					}
				})
			}
		}
	}
}
