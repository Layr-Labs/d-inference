package api

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestVersionSensitiveInferenceFailureClassification(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		msg  protocol.InferenceErrorMessage
		want bool
	}{
		{
			name: "deadline capacity",
			msg: protocol.InferenceErrorMessage{
				StatusCode:  http.StatusServiceUnavailable,
				ErrorReason: errorReasonDeadlineUnreachable,
				FailureCode: protocol.FailureCodeCapacity,
			},
		},
		{
			name: "token budget capacity",
			msg: protocol.InferenceErrorMessage{
				StatusCode:  http.StatusServiceUnavailable,
				ErrorReason: errorReasonTokenBudgetExhaust,
				FailureCode: protocol.FailureCodeCapacity,
			},
		},
		{
			name: "typed admission timeout",
			msg: protocol.InferenceErrorMessage{
				StatusCode:    http.StatusServiceUnavailable,
				FailureCode:   protocol.FailureCodeInternalFailure,
				TerminalCause: terminalCauseAdmissionTimeout,
			},
		},
		{
			name: "typed safety deadline",
			msg: protocol.InferenceErrorMessage{
				StatusCode:    http.StatusGatewayTimeout,
				FailureCode:   protocol.FailureCodeGenerationFailure,
				TerminalCause: terminalCauseSafetyDeadline,
			},
		},
		{
			name: "cancelled",
			msg: protocol.InferenceErrorMessage{
				StatusCode:  499,
				ErrorReason: errorReasonCancelled,
				FailureCode: protocol.FailureCodeCancelled,
			},
		},
		{
			name: "model unavailable",
			msg: protocol.InferenceErrorMessage{
				StatusCode:  http.StatusNotFound,
				ErrorReason: errorReasonModelLoad,
				FailureCode: protocol.FailureCodeModelUnavailable,
			},
		},
		{
			name: "model load internal fault is node local",
			msg: protocol.InferenceErrorMessage{
				StatusCode:  http.StatusInternalServerError,
				ErrorReason: errorReasonModelLoad,
				FailureCode: protocol.FailureCodeInternalFailure,
			},
		},
		{
			name: "coordinator synthetic disconnect",
			msg: protocol.InferenceErrorMessage{
				StatusCode:       http.StatusBadGateway,
				FailureCode:      protocol.FailureCodeInternalFailure,
				CoordinatorCause: protocol.CoordinatorCauseProviderDisconnected,
			},
		},
		{
			name: "tool noncompliance",
			msg: protocol.InferenceErrorMessage{
				StatusCode:  http.StatusUnprocessableEntity,
				ErrorReason: errorReasonToolNoncompliance,
				FailureCode: protocol.FailureCodeGenerationFailure,
			},
		},
		{
			name: "template compatibility",
			msg: protocol.InferenceErrorMessage{
				StatusCode:  http.StatusInternalServerError,
				ErrorReason: errorReasonJinjaTemplate,
				FailureCode: protocol.FailureCodeTemplateRender,
			},
			want: true,
		},
		{
			name: "encryption fault",
			msg: protocol.InferenceErrorMessage{
				StatusCode:  http.StatusBadGateway,
				FailureCode: protocol.FailureCodeEncryptionFailure,
			},
			want: true,
		},
		{
			name: "generation fault",
			msg: protocol.InferenceErrorMessage{
				StatusCode:  http.StatusInternalServerError,
				ErrorReason: errorReasonProviderError,
				FailureCode: protocol.FailureCodeGenerationFailure,
			},
			want: true,
		},
		{
			name: "internal fault",
			msg: protocol.InferenceErrorMessage{
				StatusCode:  http.StatusInternalServerError,
				ErrorReason: errorReasonProviderError,
				FailureCode: protocol.FailureCodeInternalFailure,
			},
			want: true,
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := versionSensitiveInferenceFailure(tc.msg, 0, 128_000); got != tc.want {
				t.Fatalf("versionSensitiveInferenceFailure() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestAvoidVersionTracksOnlyVersionSensitiveFailure(t *testing.T) {
	t.Parallel()

	current := &registry.Provider{Version: "0.8.13"}
	legacy := &registry.Provider{Version: "0.8.10"}
	unknown := &registry.Provider{}
	d := &dispatchState{model: "model", modelMaxContext: 128_000}

	deadline := protocol.InferenceErrorMessage{
		StatusCode:  http.StatusServiceUnavailable,
		ErrorReason: errorReasonDeadlineUnreachable,
		FailureCode: protocol.FailureCodeCapacity,
	}
	d.setLastInferenceError(current, deadline)
	if got := d.traits().AvoidVersion; got != "" {
		t.Fatalf("deadline refusal set AvoidVersion=%q, want empty", got)
	}

	fault := protocol.InferenceErrorMessage{
		StatusCode:  http.StatusInternalServerError,
		ErrorReason: errorReasonProviderError,
		FailureCode: protocol.FailureCodeGenerationFailure,
	}
	d.setLastInferenceError(current, fault)
	if got := d.traits().AvoidVersion; got != "0.8.13" {
		t.Fatalf("genuine fault set AvoidVersion=%q, want 0.8.13", got)
	}

	// Neutral evidence must neither redirect to the legacy version nor erase
	// the prior genuine-fault hint.
	d.setLastInferenceError(legacy, deadline)
	if got := d.traits().AvoidVersion; got != "0.8.13" {
		t.Fatalf("deadline refusal overwrote AvoidVersion=%q, want 0.8.13", got)
	}
	d.setLastInferenceError(unknown, fault)
	if got := d.traits().AvoidVersion; got != "0.8.13" {
		t.Fatalf("empty provider version cleared AvoidVersion=%q, want 0.8.13", got)
	}

	d.setLastInferenceError(legacy, fault)
	if got := d.traits().AvoidVersion; got != "0.8.10" {
		t.Fatalf("later genuine fault set AvoidVersion=%q, want 0.8.10", got)
	}
}

func TestDeadlineRetryCanUseSameVersionPeer(t *testing.T) {
	srv, _ := testServer(t)
	model := "same-version-deadline-retry"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{
		ID: model, SizeGB: 1, MinRAMGB: 24,
	}})

	first := registerBuildsProvider(srv, "current-first", model)
	currentPeer := registerBuildsProvider(srv, "current-peer", model)
	legacy := registerBuildsProvider(srv, "legacy-peer", model)
	for provider, version := range map[*registry.Provider]string{
		first:       "0.8.13",
		currentPeer: "0.8.13",
		legacy:      "0.8.10",
	} {
		provider.Mu().Lock()
		provider.Version = version
		provider.DecodeTPS = 1
		provider.PrefillTPS = 10
		provider.Mu().Unlock()
	}
	currentPeer.Mu().Lock()
	currentPeer.DecodeTPS = 100
	currentPeer.PrefillTPS = 1_000
	currentPeer.Mu().Unlock()

	d := &dispatchState{model: model, modelMaxContext: 128_000}
	deadline := protocol.InferenceErrorMessage{
		StatusCode:  http.StatusServiceUnavailable,
		ErrorReason: errorReasonDeadlineUnreachable,
		FailureCode: protocol.FailureCodeCapacity,
	}
	d.setLastInferenceError(first, deadline)
	selected, decision := srv.registry.ReserveProviderEx(model, &registry.PendingRequest{
		RequestID:             "deadline-retry",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
		Traits:                d.traits(),
	}, first.ID)
	if selected == nil || selected.ID != currentPeer.ID {
		t.Fatalf("deadline retry selected %v, want same-version healthy peer; decision=%+v", selected, decision)
	}

	fault := protocol.InferenceErrorMessage{
		StatusCode:  http.StatusInternalServerError,
		ErrorReason: errorReasonProviderError,
		FailureCode: protocol.FailureCodeGenerationFailure,
	}
	d.setLastInferenceError(first, fault)
	selected, decision = srv.registry.ReserveProviderEx(model, &registry.PendingRequest{
		RequestID:             "fault-retry",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
		Traits:                d.traits(),
	}, first.ID)
	if selected == nil || selected.ID != legacy.ID {
		t.Fatalf("version-sensitive retry selected %v, want diverse legacy peer; decision=%+v", selected, decision)
	}
}
