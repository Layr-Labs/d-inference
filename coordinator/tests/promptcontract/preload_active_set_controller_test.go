package promptcontract_test

import (
	"context"
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

func activeSetContract(index int) string { return fmt.Sprintf("%064x", index) }

func TestPreloadStandaloneAcknowledgementIsNotRegistryAuthorization(t *testing.T) {
	f := newReadinessControllerFixture(t, func(_ context.Context, _ int64, ids []string) sidecar.PreloadReport { return readinessReport(ids, "") })
	f.verified(activeSetContract(1))
	f.controller.Reconcile(context.Background())
	_, verified := f.provisioner.VerifiedPreloadArtifacts()
	state := f.controller.PlanningState(verified[0])
	if !f.controller.ReadyFor(verified[0].PromptContractID) || !state.Acknowledged || state.Participating || f.controller.NoteDemand(verified[0]) {
		t.Fatal("standalone tokenizer readiness became missing-callback authorization")
	}
}
