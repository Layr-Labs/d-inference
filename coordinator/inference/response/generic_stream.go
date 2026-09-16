package response

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"net/http"
)

type EndpointSink interface {
	Start()
	Chunk(string)
	Finish(protocol.UsageInfo)
	Error(string, string)
}

func NewEndpointSink(
	w http.ResponseWriter,
	flusher http.Flusher,
	pr *registry.PendingRequest,
	observer WriteObserver,
) EndpointSink {
	if pr.ConsumerEndpoint == MessagesEndpoint {
		return newMessagesStreamEmitter(w, flusher, pr, observer)
	}
	return &completionsStreamEmitter{observer: observer, w: w, flusher: flusher, pr: pr, stamps: newRelayStamps(pr.Profile.Parent())}
}
