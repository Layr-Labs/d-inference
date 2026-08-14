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
		StatusCode:  http.StatusUnprocessableEntity,
		ErrorReason: errorReasonToolNoncompliance,
		FailureCode: protocol.FailureCodeGenerationFailure,
	})
	if invalidCode || invalidCause {
		t.Fatalf("typed failure rejected: invalidCode=%v invalidCause=%v", invalidCode, invalidCause)
	}
	if safe.StatusCode != http.StatusUnprocessableEntity || safe.ErrorReason != errorReasonToolNoncompliance {
		t.Fatalf("typed tool contract semantics lost: %+v", safe)
	}
	if safe.Error != "inference generation failed" || strings.Contains(safe.Error, "LEAK_SENTINEL") {
		t.Fatalf("unsafe client text: %q", safe.Error)
	}
}

func TestSanitizeProviderInferenceErrorDerivesStatusFromClosedFields(t *testing.T) {
	cases := []struct {
		name   string
		code   protocol.InferenceFailureCode
		reason string
		cause  string
		status int
		want   int
	}{
		{"invalid request", protocol.FailureCodeInvalidRequest, "", "", 299, 400},
		{"tool noncompliance", protocol.FailureCodeGenerationFailure, errorReasonToolNoncompliance, "", 299, 422},
		{"template", protocol.FailureCodeTemplateRender, "", "", 299, 422},
		{"queue full", protocol.FailureCodeCapacity, errorReasonQueueFull, "", 299, 429},
		{"capacity", protocol.FailureCodeCapacity, errorReasonCapacityBusy, "", 299, 503},
		{"missing model load", protocol.FailureCodeModelUnavailable, errorReasonModelLoad, "", 404, 404},
		{"transient model load", protocol.FailureCodeCapacity, errorReasonModelLoad, "", 503, 503},
		{"faulted model load", protocol.FailureCodeInternalFailure, errorReasonModelLoad, "", 500, 500},
		{"safety deadline", protocol.FailureCodeGenerationFailure, "", terminalCauseSafetyDeadline, 299, 504},
		{"cancelled", protocol.FailureCodeGenerationFailure, "", terminalCauseCancelled, 299, 499},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			safe, _, _ := sanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
				FailureCode:   tc.code,
				ErrorReason:   tc.reason,
				TerminalCause: tc.cause,
				// The provider cannot override status except where the closed
				// model-load contract explicitly distinguishes 404 from 503.
				StatusCode: tc.status,
			})
			if safe.StatusCode != tc.want {
				t.Fatalf("status = %d, want %d; safe=%+v", safe.StatusCode, tc.want, safe)
			}
		})
	}
}

func TestSanitizeProviderInferenceErrorLegacyModelLoadCategories(t *testing.T) {
	cases := []struct {
		status int
		code   protocol.InferenceFailureCode
	}{
		{http.StatusNotFound, protocol.FailureCodeModelUnavailable},
		{http.StatusServiceUnavailable, protocol.FailureCodeCapacity},
		{http.StatusInternalServerError, protocol.FailureCodeInternalFailure},
	}
	for _, tc := range cases {
		safe, invalidCode, _ := sanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
			StatusCode:  tc.status,
			ErrorReason: errorReasonModelLoad,
		})
		if !invalidCode {
			t.Fatal("legacy frame without failure_code was not reported as drift")
		}
		if safe.FailureCode != tc.code ||
			safe.StatusCode != tc.status ||
			safe.ErrorReason != errorReasonModelLoad {
			t.Fatalf("legacy status %d normalized to %+v, want code=%q reason=%q",
				tc.status, safe, tc.code, errorReasonModelLoad)
		}
	}
}

func TestSanitizeProviderInferenceErrorPreservesLegacyBare429(t *testing.T) {
	input := protocol.InferenceErrorMessage{
		RequestID:  "req-legacy-429",
		Error:      "PROVIDER_QUEUE_DETAIL_LEAK_SENTINEL",
		StatusCode: http.StatusTooManyRequests,
	}
	safe, invalidCode, invalidCause := sanitizeProviderInferenceError(&input)
	if !invalidCode || invalidCause {
		t.Fatalf("legacy drift flags = (%v, %v), want (true, false)", invalidCode, invalidCause)
	}
	if safe.FailureCode != protocol.FailureCodeCapacity ||
		safe.ErrorReason != errorReasonQueueFull ||
		safe.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("bare legacy 429 lost queue-full semantics: %+v", safe)
	}
	if safe.Error != "request rejected: provider capacity unavailable" ||
		strings.Contains(safe.Error, "LEAK_SENTINEL") {
		t.Fatalf("legacy 429 did not receive fixed capacity message: %q", safe.Error)
	}

	second, _, _ := sanitizeProviderInferenceError(&safe)
	if !reflect.DeepEqual(safe, second) {
		t.Fatalf("legacy 429 sanitizer result is not idempotent:\nfirst:  %+v\nsecond: %+v", safe, second)
	}
}

func TestSanitizeProviderInferenceErrorTypedCapacityReasonControls429Versus503(t *testing.T) {
	cases := []struct {
		name           string
		suppliedStatus int
		reason         string
		wantStatus     int
	}{
		{"queue full remains 429", http.StatusServiceUnavailable, errorReasonQueueFull, http.StatusTooManyRequests},
		{"capacity timeout remains 503", http.StatusTooManyRequests, errorReasonCapacityTimeout, http.StatusServiceUnavailable},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			safe, invalidCode, invalidCause := sanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
				FailureCode: protocol.FailureCodeCapacity,
				StatusCode:  tc.suppliedStatus,
				ErrorReason: tc.reason,
			})
			if invalidCode || invalidCause {
				t.Fatalf("valid typed capacity frame rejected: invalidCode=%v invalidCause=%v", invalidCode, invalidCause)
			}
			if safe.FailureCode != protocol.FailureCodeCapacity ||
				safe.ErrorReason != tc.reason ||
				safe.StatusCode != tc.wantStatus {
				t.Fatalf("typed capacity frame normalized to %+v, want reason=%q status=%d",
					safe, tc.reason, tc.wantStatus)
			}
		})
	}
}

func TestLegacyBare429RemainsTransientAndHealthNeutral(t *testing.T) {
	safe, _, _ := sanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
		StatusCode: http.StatusTooManyRequests,
	})

	dispatch := &dispatchState{s: newTestServerForDispatch(t), model: "test-model"}
	dispatch.setLastInferenceError(nil, safe)
	if dispatch.shouldStopFailover() {
		t.Fatal("legacy bare 429 must remain transient below the bounded capacity retry limit")
	}
	if dispatch.capacityRetries != 1 || dispatch.terminalClientError {
		t.Fatalf("legacy bare 429 failover state = retries:%d terminalClientError:%v",
			dispatch.capacityRetries, dispatch.terminalClientError)
	}

	srv, reg, provider, pr := newBreakerExemptionHarness(t, "legacy-bare-429")
	dispatch = &dispatchState{s: srv, model: pr.Model}
	for range breakerStrikeRounds {
		dispatch.noteProviderError(provider, pr,
			safe.StatusCode, safe.Error, safe.ErrorReason, safe.TerminalCause, nil)
	}
	assertBreakerStates(t, reg, provider, pr, false)
	if !reg.CapacityCooldownActive(provider.ID, pr.Model) {
		t.Fatal("repeated legacy queue-full sheds must feed only the capacity cooldown")
	}
}

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
		{FailureCode: protocol.FailureCodeCapacity, StatusCode: 503, ErrorReason: errorReasonQueueFull},
		{FailureCode: protocol.FailureCodeCapacity, StatusCode: 429, ErrorReason: errorReasonCapacityTimeout},
		{FailureCode: protocol.FailureCodeInvalidMedia, StatusCode: 500},
		{FailureCode: protocol.FailureCodeUnsupportedMedia, StatusCode: 500},
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
