package ingress

import (
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// candidateProviderBody derives the provider-bound body the chat handler would
// send for candidateModel — the alias fallback build the admission preflight
// probes, or the resolved build itself — from the current parsed request:
// model rewritten, that build's catalog runtime defaults reconciled, the
// service reasoning policy applied, and (Responses surface) the input→chat
// lowering. It works on a shallow copy so parsed is never mutated, serializes
// once, and is memoized per request by providerBodyMemo.
func (s *Controller) candidateProviderBody(
	parsed map[string]any,
	runtimeDefaults modelRuntimeDefaults,
	candidateModel string,
	serviceConsumer, reasoningProvided, isResponsesAPI bool,
) ([]byte, error) {
	candidateParsed := make(map[string]any, len(parsed)+1)
	for key, value := range parsed {
		candidateParsed[key] = value
	}
	candidateParsed["model"] = candidateModel
	if rec, err := s.deps.Store().GetModelRegistryRecord(candidateModel); err == nil {
		runtimeDefaults.apply(candidateParsed, rec.RuntimeParameters)
	} else {
		runtimeDefaults.apply(candidateParsed, nil)
	}
	applyResolvedModelReasoningPolicy(candidateParsed, candidateModel, serviceConsumer, reasoningProvided)
	candidateBody, err := marshalForwardBody(candidateParsed)
	if err != nil {
		return nil, err
	}
	if isResponsesAPI {
		return promptcontract.LowerProviderBody(promptcontract.EndpointResponses, candidateBody)
	}
	return candidateBody, nil
}
