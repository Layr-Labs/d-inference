package dispatch

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestConfigurePendingCopiesMetadataDetails(t *testing.T) {
	t.Parallel()
	d := &execution{metadataDetails: true}
	pr := &registry.PendingRequest{}
	d.configurePending(pr)
	if !pr.MetadataDetails {
		t.Fatal("queued pending requests must inherit metadata_details")
	}

	generic := &execution{metadataDetails: true, consumerEndpoint: response.CompletionsEndpoint}
	genericPR := &registry.PendingRequest{}
	generic.configurePending(genericPR)
	if !genericPR.MetadataDetails {
		t.Fatal("configurePending still stamps the flag; snapshot must drop generic endpoints")
	}
	response.SnapshotChatCompletionMetadata(genericPR, response.ProviderInfo{ProviderID: "p"})
	if len(genericPR.ResponseMetadata) > 0 {
		t.Fatal("generic endpoints must not snapshot chat metadata into the body")
	}
}
