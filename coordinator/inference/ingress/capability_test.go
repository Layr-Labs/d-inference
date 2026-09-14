package ingress

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/inference/toolpolicy"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// The capability verdict has to tell a client whether retrying can ever help.
// "This model is served but no build of it EVER enforces tool_choice" is
// permanent (400); a model the fleet does not serve at all, or an enforcing
// provider that is merely trust-lapsed right now, is a retryable condition
// (503). And `none`, which needs no enforcement, must clear both gates.
func TestToolConstraintCapabilityErrorSeparatesPermanentFromTransient(t *testing.T) {
	const model = "gpt-oss-20b"
	failFast := func(
		t *testing.T,
		hasTools, requiresConstraint bool,
		configure func(*registry.Provider),
	) *httptest.ResponseRecorder {
		t.Helper()
		srv, _ := testController(t)
		srv.deps.Registry().SetModelCatalog([]registry.CatalogEntry{{ID: model}})
		if configure != nil {
			configure(registerBuildsProvider(srv, "serving-provider", model))
		}
		response := httptest.NewRecorder()
		handled := srv.visionToolsFailFast(
			response, model, model, false, hasTools, requiresConstraint,
			"required", false, dispatch.RoutePolicy{}, nil)
		if requiresConstraint && !handled {
			t.Fatal("incapable constrained request was allowed into the queue")
		}
		if !requiresConstraint && handled {
			t.Fatalf("unconstrained request was blocked: %d %s",
				response.Code, response.Body.String())
		}
		return response
	}

	// Above the tools floor but advertising no tool-constraint protocol: the
	// fleet serves the model, nobody ever enforces on it — permanent.
	served := failFast(t, true, true, func(p *registry.Provider) {
		p.Mu().Lock()
		p.Version = "0.6.5"
		p.Mu().Unlock()
	})
	if served.Code != http.StatusBadRequest ||
		!strings.Contains(served.Body.String(),
			"inference-enforced tool_choice (required/named) is not supported") {
		t.Fatalf("permanent incapability reported as capacity: %d %s",
			served.Code, served.Body.String())
	}

	absent := failFast(t, false, true, nil)
	if absent.Code != http.StatusServiceUnavailable ||
		!strings.Contains(absent.Body.String(),
			"advertises inference-time tool_choice enforcement") {
		t.Fatalf("absent model lost its retryable capacity error: %d %s",
			absent.Code, absent.Body.String())
	}

	// A provider that ADVERTISES enforcement (protocol v1 + the concrete
	// model) but sits below the registry's trust minimum is transiently
	// unroutable — an outage, not an incapability. The verdict must stay
	// retryable (503); reporting the permanent 400 would tell clients this
	// model can never enforce tool_choice while the fleet is merely
	// re-attesting.
	lapsed := failFast(t, false, true, func(p *registry.Provider) {
		p.Mu().Lock()
		p.Version = "0.7.10"
		p.ToolConstraintProtocol = registry.ToolConstraintProtocolV1
		p.ToolConstraintModels = map[string]struct{}{model: {}}
		p.TrustLevel = registry.TrustSelfSigned
		p.Mu().Unlock()
	})
	if lapsed.Code != http.StatusServiceUnavailable ||
		!strings.Contains(lapsed.Body.String(),
			"advertises inference-time tool_choice enforcement") {
		t.Fatalf("transient trust lapse reported as permanent incapability: %d %s",
			lapsed.Code, lapsed.Body.String())
	}

	// tool_choice "none" derives requiresToolConstraint=false, so a model with
	// no enforcing provider at all still serves it.
	mode, err := toolpolicy.ValidateBytes([]byte(
		`{"model":"gpt-oss-20b","messages":[{"role":"user","content":"x"}],"tool_choice":"none"}`))
	if err != nil {
		t.Fatal(err)
	}
	failFast(t, false, mode.Mode.RequiresInferenceConstraint(), nil)
}
