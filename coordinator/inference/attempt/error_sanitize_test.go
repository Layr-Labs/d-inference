package attempt

import (
	"bytes"
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
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
			safe, invalidCode, invalidCause := SanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
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
			if safe.ErrorReason != ErrorReasonProviderError || safe.TerminalCause != "" {
				t.Fatalf("untrusted typed fields survived: %+v", safe)
			}
		})
	}
}

func TestSanitizeProviderInferenceErrorLegacyFailsClosed(t *testing.T) {
	safe, invalidCode, invalidCause := SanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
		RequestID:     "req-legacy",
		Error:         "prompt contents and /Users/provider/private/path",
		StatusCode:    http.StatusOK,
		ErrorReason:   "prompt-derived-reason",
		TerminalCause: TerminalCauseSafetyDeadline,
	})
	if !invalidCode || invalidCause {
		t.Fatalf("invalidCode=%v invalidCause=%v", invalidCode, invalidCause)
	}
	if safe.FailureCode != protocol.FailureCodeGenerationFailure || safe.Error != "inference generation failed" {
		t.Fatalf("legacy frame did not fail closed: %+v", safe)
	}
	// A valid bounded cause may retain its health semantics; it still cannot
	// preserve legacy prose or choose an arbitrary status.
	if safe.TerminalCause != TerminalCauseSafetyDeadline || safe.StatusCode != http.StatusGatewayTimeout {
		t.Fatalf("bounded terminal semantics lost: %+v", safe)
	}
	if safe.ErrorReason != ErrorReasonProviderError {
		t.Fatalf("legacy reason must not override fail-closed classification: %+v", safe)
	}
}

func TestSanitizeProviderInferenceErrorPreservesTypedToolNoncompliance422(t *testing.T) {
	safe, invalidCode, invalidCause := SanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
		RequestID:   "req-tool-contract",
		Error:       "TOOL_OUTPUT_LEAK_SENTINEL",
		StatusCode:  http.StatusUnprocessableEntity,
		ErrorReason: ErrorReasonToolNoncompliance,
		FailureCode: protocol.FailureCodeGenerationFailure,
	})
	if invalidCode || invalidCause {
		t.Fatalf("typed failure rejected: invalidCode=%v invalidCause=%v", invalidCode, invalidCause)
	}
	if safe.StatusCode != http.StatusUnprocessableEntity || safe.ErrorReason != ErrorReasonToolNoncompliance {
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
		{"tool noncompliance", protocol.FailureCodeGenerationFailure, ErrorReasonToolNoncompliance, "", 299, 422},
		{"template", protocol.FailureCodeTemplateRender, "", "", 299, 422},
		{"queue full", protocol.FailureCodeCapacity, ErrorReasonQueueFull, "", 299, 429},
		{"capacity", protocol.FailureCodeCapacity, ErrorReasonCapacityBusy, "", 299, 503},
		{"missing model load", protocol.FailureCodeModelUnavailable, ErrorReasonModelLoad, "", 404, 404},
		{"transient model load", protocol.FailureCodeCapacity, ErrorReasonModelLoad, "", 503, 503},
		{"faulted model load", protocol.FailureCodeInternalFailure, ErrorReasonModelLoad, "", 500, 500},
		{"safety deadline", protocol.FailureCodeGenerationFailure, "", TerminalCauseSafetyDeadline, 299, 504},
		{"cancelled", protocol.FailureCodeGenerationFailure, "", TerminalCauseCancelled, 299, 499},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			safe, _, _ := SanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
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
		safe, invalidCode, _ := SanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
			StatusCode:  tc.status,
			ErrorReason: ErrorReasonModelLoad,
		})
		if !invalidCode {
			t.Fatal("legacy frame without failure_code was not reported as drift")
		}
		if safe.FailureCode != tc.code ||
			safe.StatusCode != tc.status ||
			safe.ErrorReason != ErrorReasonModelLoad {
			t.Fatalf("legacy status %d normalized to %+v, want code=%q reason=%q",
				tc.status, safe, tc.code, ErrorReasonModelLoad)
		}
	}
}

func TestSanitizeProviderInferenceErrorPreservesLegacyBare429(t *testing.T) {
	input := protocol.InferenceErrorMessage{
		RequestID:  "req-legacy-429",
		Error:      "PROVIDER_QUEUE_DETAIL_LEAK_SENTINEL",
		StatusCode: http.StatusTooManyRequests,
	}
	safe, invalidCode, invalidCause := SanitizeProviderInferenceError(&input)
	if !invalidCode || invalidCause {
		t.Fatalf("legacy drift flags = (%v, %v), want (true, false)", invalidCode, invalidCause)
	}
	if safe.FailureCode != protocol.FailureCodeCapacity ||
		safe.ErrorReason != ErrorReasonQueueFull ||
		safe.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("bare legacy 429 lost queue-full semantics: %+v", safe)
	}
	if safe.Error != "request rejected: provider capacity unavailable" ||
		strings.Contains(safe.Error, "LEAK_SENTINEL") {
		t.Fatalf("legacy 429 did not receive fixed capacity message: %q", safe.Error)
	}

	second, _, _ := SanitizeProviderInferenceError(&safe)
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
		{"queue full remains 429", http.StatusServiceUnavailable, ErrorReasonQueueFull, http.StatusTooManyRequests},
		{"capacity timeout remains 503", http.StatusTooManyRequests, ErrorReasonCapacityTimeout, http.StatusServiceUnavailable},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			safe, invalidCode, invalidCause := SanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
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

func TestSanitizeProviderInferenceErrorPreservesDeadlineUnreachable(t *testing.T) {
	for _, input := range []protocol.InferenceErrorMessage{
		{
			FailureCode: protocol.FailureCodeCapacity,
			StatusCode:  http.StatusInternalServerError,
			ErrorReason: ErrorReasonDeadlineUnreachable,
		},
		{
			// Mixed-fleet compatibility: a provider may add the closed reason
			// before it adds failure_code.
			StatusCode:  http.StatusServiceUnavailable,
			ErrorReason: ErrorReasonDeadlineUnreachable,
		},
	} {
		safe, _, invalidCause := SanitizeProviderInferenceError(&input)
		if invalidCause {
			t.Fatal("deadline refusal unexpectedly invalidated terminal cause")
		}
		if safe.FailureCode != protocol.FailureCodeCapacity ||
			safe.ErrorReason != ErrorReasonDeadlineUnreachable ||
			safe.StatusCode != http.StatusServiceUnavailable {
			t.Fatalf("deadline refusal normalized to %+v", safe)
		}
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
		{FailureCode: protocol.FailureCodeCapacity, StatusCode: 503, ErrorReason: ErrorReasonQueueFull},
		{FailureCode: protocol.FailureCodeCapacity, StatusCode: 429, ErrorReason: ErrorReasonCapacityTimeout},
		{FailureCode: protocol.FailureCodeInvalidMedia, StatusCode: 500},
		{FailureCode: protocol.FailureCodeUnsupportedMedia, StatusCode: 500},
	}
	for _, input := range cases {
		input.RequestID = "coordinator-request-id"
		input.Error = "IDEMPOTENCE_LEAK_SENTINEL"
		first, _, _ := SanitizeProviderInferenceError(&input)
		second, _, _ := SanitizeProviderInferenceError(&first)
		if !reflect.DeepEqual(first, second) {
			t.Fatalf("sanitizer is not idempotent for code=%q status=%d:\nfirst:  %+v\nsecond: %+v",
				input.FailureCode, input.StatusCode, first, second)
		}
	}
}

// TestSanitizeProviderInferenceErrorLiveBudgetPresence pins the P1-4 wire
// semantics at the confidentiality boundary: the live budget is a POINTER so
// presence itself is signal — nil (legacy frame) stays nil and leaves the
// stale-heartbeat fallback in play, an EXPLICIT zero ("no headroom right
// now", transient) survives, and a nonsense negative is treated as absent.
// The safe copy must never alias the raw provider message's allocation.
func TestSanitizeProviderInferenceErrorLiveBudgetPresence(t *testing.T) {
	base := protocol.InferenceErrorMessage{
		Type:        protocol.TypeInferenceError,
		StatusCode:  http.StatusServiceUnavailable,
		FailureCode: protocol.FailureCodeCapacity,
	}

	legacy := base
	safe, _, _ := SanitizeProviderInferenceError(&legacy)
	if safe.AvailableTokenBudget != nil {
		t.Fatalf("legacy nil budget crossed the boundary as %v, want nil", *safe.AvailableTokenBudget)
	}

	zero := base
	zero.RejectionReason = protocol.RejectionReasonTokenBudget
	zero.AvailableTokenBudget = i64ptr(0)
	safe, _, _ = SanitizeProviderInferenceError(&zero)
	if safe.AvailableTokenBudget == nil || *safe.AvailableTokenBudget != 0 {
		t.Fatalf("explicit zero live budget = %v, want a preserved 0", safe.AvailableTokenBudget)
	}
	if safe.AvailableTokenBudget == zero.AvailableTokenBudget {
		t.Fatal("safe frame aliases the raw provider message's budget allocation")
	}

	negative := base
	negative.AvailableTokenBudget = i64ptr(-5)
	safe, _, _ = SanitizeProviderInferenceError(&negative)
	if safe.AvailableTokenBudget != nil {
		t.Fatalf("negative budget crossed the boundary as %v, want dropped", *safe.AvailableTokenBudget)
	}
}

// The provider profile crosses the sanitizer as an opaque byte copy (it is
// validated later, on the profile sink), while the raw Error prose still
// never does — with or without a profile attached.
func TestSanitizeProviderInferenceErrorCarriesProfileNeverErrorText(t *testing.T) {
	profile := []byte(`{"schema":1,"total_us":30000500,"cancel_stage":"none"}`)
	input := &protocol.InferenceErrorMessage{
		Type:          protocol.TypeInferenceError,
		RequestID:     "req-profile",
		Error:         "PROFILE_PATH_LEAK_SENTINEL /Users/provider/prompt.txt",
		StatusCode:    http.StatusServiceUnavailable,
		ErrorReason:   ErrorReasonCapacityTimeout,
		FailureCode:   protocol.FailureCodeCapacity,
		TerminalCause: TerminalCauseAdmissionTimeout,
		Profile:       json.RawMessage(append([]byte(nil), profile...)),
	}
	safe, invalidCode, invalidCause := SanitizeProviderInferenceError(input)
	if invalidCode || invalidCause {
		t.Fatalf("typed frame rejected: invalidCode=%v invalidCause=%v", invalidCode, invalidCause)
	}
	if !bytes.Equal(safe.Profile, profile) {
		t.Fatalf("profile did not survive sanitization: %s", safe.Profile)
	}
	internal := NormalizeInferenceErrorForInternalUse(*input)
	if !bytes.Equal(internal.Profile, profile) {
		t.Fatalf("internal normalization dropped the profile: %s", internal.Profile)
	}
	// A byte COPY: mutating the provider's buffer afterwards cannot reach the
	// retained profile.
	input.Profile[2] = 'X'
	if !bytes.Equal(safe.Profile, profile) || !bytes.Equal(internal.Profile, profile) {
		t.Fatal("sanitizer aliased the provider's profile buffer")
	}
	wire, err := json.Marshal(safe)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(wire, []byte(`"profile":{"schema":1,"total_us":30000500,"cancel_stage":"none"}`)) {
		t.Fatalf("profile missing from sanitized wire: %s", wire)
	}
	if bytes.Contains(wire, []byte("LEAK_SENTINEL")) || safe.Error != "request rejected: provider capacity unavailable" {
		t.Fatalf("raw error text survived alongside the profile: %s", wire)
	}
	if safe.StatusCode != http.StatusServiceUnavailable || safe.TerminalCause != TerminalCauseAdmissionTimeout {
		t.Fatalf("closed fields changed by profile carry-through: %+v", safe)
	}

	// Idempotent with the profile attached, and nil stays nil (legacy frame).
	second, _, _ := SanitizeProviderInferenceError(&safe)
	if !reflect.DeepEqual(safe, second) {
		t.Fatalf("sanitizer not idempotent with profile:\nfirst:  %+v\nsecond: %+v", safe, second)
	}
	legacy, _, _ := SanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
		Error: "LEGACY_LEAK_SENTINEL", StatusCode: http.StatusTooManyRequests,
	})
	if legacy.Profile != nil {
		t.Fatalf("legacy frame grew a profile: %s", legacy.Profile)
	}
}
