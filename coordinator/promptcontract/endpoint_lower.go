package promptcontract

import "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/endpoint"

var (
	ErrEndpointBodyNotObject   = endpoint.ErrEndpointBodyNotObject
	ErrEndpointBodyInvalid     = endpoint.ErrEndpointBodyInvalid
	ErrEndpointBodyUnsupported = endpoint.ErrEndpointBodyUnsupported
)

func LowerProviderBody(route Endpoint, body []byte) ([]byte, error) {
	return endpoint.LowerProviderBody(route, body)
}

func LowerResponsesInferenceBody(body []byte) ([]byte, error) {
	return endpoint.LowerResponsesInferenceBody(body)
}
