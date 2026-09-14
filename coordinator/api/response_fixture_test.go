package api

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Test-only bindings keep whole-API fixtures on the shared response operations.

type committedProviderInfo = response.ProviderInfo

const completionsEndpoint = response.CompletionsEndpoint
const messagesEndpoint = response.MessagesEndpoint
const metadataDetailsHeader = response.MetadataDetailsHeader

var snapshotChatCompletionMetadata = response.SnapshotChatCompletionMetadata

const maxCoalescedChunks = response.MaxBatchChunks
const maxCoalescedBatchBytes = response.MaxBatchBytes

func writeNonStreamBody(w http.ResponseWriter, rp *registry.RequestProfile, v any) {
	response.New(response.Dependencies{Observer: responseWriteObserver{}}).Body(w, rp, v)
}
