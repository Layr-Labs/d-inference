package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"testing"
)

func TestConfigurePendingCopiesMetadataDetails(t *testing.T) {
	t.Parallel()
	d := &dispatchState{metadataDetails: true}
	pr := &registry.PendingRequest{}
	d.configurePending(pr)
	if !pr.MetadataDetails {
		t.Fatal("queued pending requests must inherit metadata_details")
	}

	generic := &dispatchState{metadataDetails: true, consumerEndpoint: completionsEndpoint}
	genericPR := &registry.PendingRequest{}
	generic.configurePending(genericPR)
	if !genericPR.MetadataDetails {
		t.Fatal("configurePending still stamps the flag; snapshot must drop generic endpoints")
	}
	snapshotChatCompletionMetadata(genericPR, committedProviderInfo{ProviderID: "p"})
	if len(genericPR.ResponseMetadata) > 0 {
		t.Fatal("generic endpoints must not snapshot chat metadata into the body")
	}
}
