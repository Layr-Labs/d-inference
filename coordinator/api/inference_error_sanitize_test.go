package api

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestSanitizeProviderInferenceErrorDiscardsUntrustedStrings(t *testing.T) {
	secrets := []string{
		"RAW_LEAK_SENTINEL",
		`ESCAPED_LEAK_SENTINEL\"quoted`,
		"https://provider.invalid/exfil?value=URL_LEAK_SENTINEL",
		"NEWLINE_LEAK_SENTINEL\nsecond line",
	}
	for _, secret := range secrets {
		t.Run(strings.Split(secret, "_")[0], func(t *testing.T) {
			safe, invalidCode, invalidCause := sanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
				Type:          protocol.TypeInferenceError,
				RequestID:     "coordinator-request-id",
				Error:         secret,
				StatusCode:    299,
				ErrorReason:   secret,
				TerminalCause: secret,
				FailureCode:   protocol.FailureCodeGenerationFailure,
			})
			if invalidCode {
				t.Fatal("valid failure code marked invalid")
			}
			if !invalidCause {
				t.Fatal("off-vocabulary terminal cause was not rejected")
			}
			b, err := json.Marshal(safe)
			if err != nil {
				t.Fatal(err)
			}
			if bytes.Contains(b, []byte(secret)) || bytes.Contains(b, []byte("LEAK_SENTINEL")) {
				t.Fatalf("secret survived sanitizer: %s", b)
			}
			if safe.Error != "inference generation failed" || safe.StatusCode != http.StatusInternalServerError {
				t.Fatalf("unexpected safe failure: %+v", safe)
			}
			if safe.ErrorReason != errorReasonProviderError || safe.TerminalCause != "" {
				t.Fatalf("untrusted typed fields survived: %+v", safe)
			}
		})
	}
}

func TestSanitizeProviderInferenceErrorLegacyFailsClosed(t *testing.T) {
	safe, invalidCode, invalidCause := sanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
		RequestID:     "req-legacy",
		Error:         "prompt contents and /Users/provider/private/path",
		StatusCode:    http.StatusOK,
		ErrorReason:   "prompt-derived-reason",
		TerminalCause: terminalCauseSafetyDeadline,
	})
	if !invalidCode || invalidCause {
		t.Fatalf("invalidCode=%v invalidCause=%v", invalidCode, invalidCause)
	}
	if safe.FailureCode != protocol.FailureCodeGenerationFailure || safe.Error != "inference generation failed" {
		t.Fatalf("legacy frame did not fail closed: %+v", safe)
	}
	// A valid bounded cause may retain its health semantics; it still cannot
	// preserve legacy prose or choose an arbitrary status.
	if safe.TerminalCause != terminalCauseSafetyDeadline || safe.StatusCode != http.StatusGatewayTimeout {
		t.Fatalf("bounded terminal semantics lost: %+v", safe)
	}
	if safe.ErrorReason != errorReasonProviderError {
		t.Fatalf("legacy reason must not override fail-closed classification: %+v", safe)
	}
}

func TestSanitizeProviderInferenceErrorPreservesTypedToolNoncompliance422(t *testing.T) {
	safe, invalidCode, invalidCause := sanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
		RequestID:   "req-tool-contract",
		Error:       "TOOL_OUTPUT_LEAK_SENTINEL",
		StatusCode:  599,
		ErrorReason: errorReasonToolNoncompliance,
		FailureCode: protocol.FailureCodeInvalidRequest,
	})
	if invalidCode || invalidCause {
		t.Fatalf("typed failure rejected: invalidCode=%v invalidCause=%v", invalidCode, invalidCause)
	}
	if safe.StatusCode != http.StatusUnprocessableEntity || safe.ErrorReason != errorReasonToolNoncompliance {
		t.Fatalf("typed tool contract semantics lost: %+v", safe)
	}
	if safe.Error != "invalid inference request" || strings.Contains(safe.Error, "LEAK_SENTINEL") {
		t.Fatalf("unsafe client text: %q", safe.Error)
	}
}

func TestSanitizeProviderInferenceErrorDerivesStatusFromClosedFields(t *testing.T) {
	cases := []struct {
		name   string
		code   protocol.InferenceFailureCode
		reason string
		cause  string
		want   int
	}{
		{"invalid request", protocol.FailureCodeInvalidRequest, "", "", 400},
		{"tool noncompliance", protocol.FailureCodeInvalidRequest, errorReasonToolNoncompliance, "", 422},
		{"template", protocol.FailureCodeTemplateRender, "", "", 422},
		{"queue full", protocol.FailureCodeCapacity, errorReasonQueueFull, "", 429},
		{"capacity", protocol.FailureCodeCapacity, errorReasonCapacityBusy, "", 503},
		{"safety deadline", protocol.FailureCodeGenerationFailure, "", terminalCauseSafetyDeadline, 504},
		{"cancelled", protocol.FailureCodeGenerationFailure, "", terminalCauseCancelled, 499},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			safe, _, _ := sanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
				FailureCode:   tc.code,
				ErrorReason:   tc.reason,
				TerminalCause: tc.cause,
				// The provider cannot override the status selected by closed fields.
				StatusCode: 299,
			})
			if safe.StatusCode != tc.want {
				t.Fatalf("status = %d, want %d; safe=%+v", safe.StatusCode, tc.want, safe)
			}
		})
	}
}

func TestSanitizeProviderInferenceErrorIsIdempotent(t *testing.T) {
	cases := []protocol.InferenceErrorMessage{
		{StatusCode: 400},
		{StatusCode: 404},
		{StatusCode: 422},
		{StatusCode: 429},
		{StatusCode: 499},
		{StatusCode: 500},
		{StatusCode: 502},
		{StatusCode: 503},
		{StatusCode: 504},
		{FailureCode: "unknown_code", StatusCode: 299},
	}
	for _, input := range cases {
		input.RequestID = "coordinator-request-id"
		input.Error = "IDEMPOTENCE_LEAK_SENTINEL"
		first, _, _ := sanitizeProviderInferenceError(&input)
		second, _, _ := sanitizeProviderInferenceError(&first)
		if !reflect.DeepEqual(first, second) {
			t.Fatalf("sanitizer is not idempotent for code=%q status=%d:\nfirst:  %+v\nsecond: %+v",
				input.FailureCode, input.StatusCode, first, second)
		}
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
			ChunkCh:    make(chan string, 1),
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
		outcome, err := json.Marshal(preCommitProviderErrorOutcome(pr, delivered))
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
