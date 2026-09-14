package api

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestTypedMediaFailuresUseFixedClientMessages(t *testing.T) {
	srv := &Server{logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	cases := []struct {
		name       string
		code       protocol.InferenceFailureCode
		wantStatus int
		wantText   string
	}{
		{"invalid media", protocol.FailureCodeInvalidMedia, http.StatusBadRequest, "invalid media input"},
		{"unsupported media", protocol.FailureCodeUnsupportedMedia, http.StatusUnsupportedMediaType, "unsupported media input"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			srv.writeGenericProviderError(recorder, protocol.InferenceErrorMessage{
				Error:       "PROVIDER_MEDIA_DETAIL_LEAK_SENTINEL",
				StatusCode:  http.StatusInternalServerError,
				FailureCode: tc.code,
			})
			if recorder.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", recorder.Code, tc.wantStatus, recorder.Body.String())
			}
			if !strings.Contains(recorder.Body.String(), tc.wantText) ||
				strings.Contains(recorder.Body.String(), "LEAK_SENTINEL") {
				t.Fatalf("client body did not use fixed %q message: %s", tc.code, recorder.Body.String())
			}
		})
	}
}

func TestProviderInferenceErrorSentinelsDoNotReachLogsChannelOutcomeOrClient(t *testing.T) {
	var logs bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	reg := registry.New(logger)
	srv := &Server{registry: reg, logger: logger}
	provider := reg.Register("safe-provider", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M3", MemoryGB: 32},
		Models:   []protocol.ModelInfo{{ID: "safe-model", ModelType: "chat"}},
	})
	if provider == nil {
		t.Fatal("provider registration failed")
	}

	secrets := []string{
		"RAW_LEAK_SENTINEL",
		`ESCAPED_LEAK_SENTINEL\"quoted`,
		"https://provider.invalid/?q=URL_LEAK_SENTINEL",
		"NEWLINE_LEAK_SENTINEL\nsecond line",
	}
	for i, secret := range secrets {
		requestID := "req-safe-" + string(rune('a'+i))
		pr := &registry.PendingRequest{
			RequestID:  requestID,
			ProviderID: provider.ID,
			Model:      "safe-model",
			ChunkCh:    make(chan registry.ProviderChunk, 1),
			CompleteCh: make(chan protocol.UsageInfo, 1),
			ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		}
		provider.AddPending(pr)
		srv.handleInferenceError(provider.ID, provider, &protocol.InferenceErrorMessage{
			Type:          protocol.TypeInferenceError,
			RequestID:     requestID,
			Error:         secret,
			StatusCode:    299,
			ErrorReason:   secret,
			TerminalCause: secret,
			FailureCode:   protocol.FailureCodeGenerationFailure,
		})

		delivered := <-pr.ErrorCh
		wire, err := json.Marshal(delivered)
		if err != nil {
			t.Fatal(err)
		}
		outcome, err := json.Marshal(attempt.PreCommitProviderErrorOutcome(pr, delivered))
		if err != nil {
			t.Fatal(err)
		}
		recorder := httptest.NewRecorder()
		srv.writeGenericProviderError(recorder, protocol.InferenceErrorMessage{
			Error:       secret,
			ErrorReason: secret,
			StatusCode:  http.StatusInternalServerError,
		})
		for surface, content := range map[string]string{
			"channel": string(wire),
			"outcome": string(outcome),
			"client":  recorder.Body.String(),
		} {
			if strings.Contains(content, "LEAK_SENTINEL") {
				t.Fatalf("%s leaked provider text: %s", surface, content)
			}
		}
	}

	// Unknown request IDs are provider-controlled and must not enter logs.
	srv.handleInferenceError(provider.ID, provider, &protocol.InferenceErrorMessage{
		Type:        protocol.TypeInferenceError,
		RequestID:   "UNKNOWN_REQUEST_ID_LEAK_SENTINEL",
		Error:       "UNKNOWN_ERROR_LEAK_SENTINEL",
		FailureCode: protocol.FailureCodeInternalFailure,
	})
	if strings.Contains(logs.String(), "LEAK_SENTINEL") {
		t.Fatalf("provider-controlled string reached coordinator logs:\n%s", logs.String())
	}
}

func TestWriteGenericProviderErrorIgnoresRawErrorEvenWithValidCode(t *testing.T) {
	srv := &Server{logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	recorder := httptest.NewRecorder()
	srv.writeGenericProviderError(recorder, protocol.InferenceErrorMessage{
		Error:       "CLIENT_LEAK_SENTINEL",
		StatusCode:  http.StatusBadGateway,
		FailureCode: protocol.FailureCodeEncryptionFailure,
	})
	if strings.Contains(recorder.Body.String(), "LEAK_SENTINEL") {
		t.Fatalf("raw provider error reached client: %s", recorder.Body.String())
	}
	if !strings.Contains(recorder.Body.String(), "encrypted inference transport failed") {
		t.Fatalf("fixed client message missing: %s", recorder.Body.String())
	}
}
