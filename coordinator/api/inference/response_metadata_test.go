package inference

import (
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestConfigurePendingCopiesMetadataDetails(t *testing.T) {
	t.Parallel()
	d := &dispatchState{metadataDetails: true}
	pr := &registry.PendingRequest{}
	d.configurePending(pr)
	if !pr.MetadataDetails {
		t.Fatal("queued pending requests must inherit metadata_details")
	}

	generic := &dispatchState{metadataDetails: true, consumerEndpoint: inreq.CompletionsEndpoint}
	genericPR := &registry.PendingRequest{}
	generic.configurePending(genericPR)
	if !genericPR.MetadataDetails {
		t.Fatal("configurePending still stamps the flag; snapshot must drop generic endpoints")
	}
	inresp.SnapshotChatCompletionMetadata(genericPR, inresp.CommittedProviderInfo{ProviderID: "p"})
	if inresp.HasChatCompletionMetadata(genericPR) {
		t.Fatal("generic endpoints must not snapshot chat metadata into the body")
	}
}
