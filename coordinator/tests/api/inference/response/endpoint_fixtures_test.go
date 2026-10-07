package response_test

import (
	production "github.com/eigeninference/d-inference/coordinator/api/inference/response"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const fixtureMaxCoalescedBatchBytes = 256 << 10
const fixtureMaxLogicalToolCalls = 128

func messagesResponse(pr *registry.PendingRequest, message production.ExtractedMessage, usage protocol.UsageInfo) map[string]any {
	return production.BuildGenericEndpointResponse(endpointRequest(pr, inreq.MessagesEndpoint), message, usage).(map[string]any)
}

func completionsResponse(pr *registry.PendingRequest, message production.ExtractedMessage, usage protocol.UsageInfo) map[string]any {
	return production.BuildGenericEndpointResponse(endpointRequest(pr, inreq.CompletionsEndpoint), message, usage).(map[string]any)
}

// Only response descriptors cross this boundary; request synchronization state
// must not be copied just to select an endpoint representation.
func endpointRequest(pr *registry.PendingRequest, endpoint string) *registry.PendingRequest {
	return &registry.PendingRequest{
		ConsumerEndpoint: endpoint, RequestID: pr.RequestID, PublicModel: pr.PublicModel, Model: pr.Model,
		RequestedMaxTokens: pr.RequestedMaxTokens, MatchedStopSequence: pr.MatchedStopSequence,
		SESignature: pr.SESignature, ResponseHash: pr.ResponseHash,
	}
}
