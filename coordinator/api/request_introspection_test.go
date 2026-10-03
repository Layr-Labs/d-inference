package api

import (
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

// The whole-body fallback must observe mutations made AFTER introspection
// (the handler injects max_tokens and rewrites the model between the two
// call sites), so it is evaluated lazily at the call site.
func TestRequestShapeFallbackIsLazy(t *testing.T) {
	parsed := map[string]any{"model": "m", "messages": nil}
	shape := inreq.IntrospectRequest(parsed)
	before := shape.RoutingPromptTokens(parsed)
	beforeBilling := shape.BillingPromptTokens(parsed)
	parsed["model"] = "a-much-longer-concrete-build-identifier"
	parsed["max_tokens"] = 8192
	if got := shape.RoutingPromptTokens(parsed); got <= before {
		t.Fatalf("routing fallback ignored later mutations: %d <= %d", got, before)
	}
	if got := shape.BillingPromptTokens(parsed); got <= beforeBilling {
		t.Fatalf("billing fallback ignored later mutations: %d <= %d", got, beforeBilling)
	}
	if got := inreq.EstimatePromptTokens(parsed); got != shape.RoutingPromptTokens(parsed) {
		t.Fatalf("wrapper = %d, shape = %d", got, shape.RoutingPromptTokens(parsed))
	}
}
