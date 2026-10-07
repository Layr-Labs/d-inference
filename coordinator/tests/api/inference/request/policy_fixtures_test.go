package request_test

import production "github.com/eigeninference/d-inference/coordinator/api/inference/request"

const (
	fixtureMaxToolNormalizationBytes  = 4 * 1024 * 1024
	fixtureMaxToolSchemaDepth         = 64
	fixtureServiceReasoningOptInModel = "qwen3.6-35b-a3b-vl-mtp-mxfp8"
)

func validateToolConstraintRequest(body []byte) (production.ToolChoiceMode, error) {
	policy, err := production.ValidateToolConstraintPolicy(body)
	return policy.Mode, err
}
