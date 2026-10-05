package providerwire

import (
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Catalog interface {
	GetModelRegistryRecord(string) (*store.ModelRegistryRecord, error)
}

// CandidateBody reconciles a candidate build on a shallow copy of the request,
// preserving the handler's parsed map for subsequent admission/fallback work.
func CandidateBody(catalog Catalog, parsed map[string]any, runtimeDefaults inreq.ModelRuntimeDefaults,
	candidateModel string, serviceConsumer, reasoningProvided, isResponsesAPI bool,
) ([]byte, error) {
	candidateParsed := make(map[string]any, len(parsed)+1)
	for key, value := range parsed {
		candidateParsed[key] = value
	}
	candidateParsed["model"] = candidateModel
	if rec, err := catalog.GetModelRegistryRecord(candidateModel); err == nil {
		runtimeDefaults.Apply(candidateParsed, rec.RuntimeParameters)
	} else {
		runtimeDefaults.Apply(candidateParsed, nil)
	}
	inreq.ApplyResolvedModelReasoningPolicy(candidateParsed, candidateModel, serviceConsumer, reasoningProvided)
	candidateBody, err := inreq.MarshalForwardBody(candidateParsed)
	if err != nil {
		return nil, err
	}
	if isResponsesAPI {
		return promptcontract.LowerResponsesInferenceBody(candidateBody)
	}
	return candidateBody, nil
}
