package registry_test

import (
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestPendingChunkIngressIsVisibleBeforeClassification(t *testing.T) {
	pr := &production.PendingRequest{}
	receivedAt := pr.BeginProviderChunkIngress()
	pr.FirstContentDeadline = receivedAt.Add(time.Millisecond)
	if !pr.FirstContentIngressArrivedByDeadline() {
		t.Fatal("on-time chunk under classification was invisible to deadline arbitration")
	}
	if !pr.FinishProviderChunkIngress(receivedAt, true) {
		t.Fatal("first content classification was not claimed")
	}
	if !pr.FirstContentIngressArrivedByDeadline() {
		t.Fatal("classified on-time content became invisible before channel delivery")
	}
}
