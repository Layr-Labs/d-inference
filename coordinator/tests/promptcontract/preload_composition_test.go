package promptcontract_test

import (
	"context"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func TestPreloadControllerComposesRealOwnersForEmptyCatalog(t *testing.T) {
	base, err := url.Parse("https://artifacts.invalid/")
	if err != nil {
		t.Fatal(err)
	}
	cache, err := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{Root: readOnlyTempRoot(t), BaseURL: base})
	if err != nil {
		t.Fatal(err)
	}
	provisioner, err := promptcontract.NewProvisioner(context.Background(), cache, promptcontract.ProvisionerConfig{})
	if err != nil {
		t.Fatal(err)
	}
	defer provisioner.Close()
	if err := provisioner.Reconcile(nil); err != nil {
		t.Fatal(err)
	}
	supervisor, _ := startSupervisorHelper(t)
	waitForSupervisor(t, supervisor, func(status promptcontract.SupervisorStatus) bool { return status.Ready })
	controller, err := promptcontract.NewPreloadController(provisioner, supervisor, promptcontract.PreloadControllerConfig{PollInterval: time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	controller.Start(context.Background())
	defer controller.Close()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		status := controller.Status()
		// An empty verified set closes participation without an empty preload.
		// The controller reports this reason only after it has observed both the
		// real catalog generation and the real running child generation.
		if status.LastError == "no verified prompt contracts" {
			if status.Ready || status.CatalogGeneration != 0 || status.ChildGeneration != 0 || status.ContractCount != 0 ||
				status.Runs != 0 || status.Failures != 0 || controller.ReadyFor(strings.Repeat("a", 64)) {
				t.Fatalf("composed empty-catalog handoff was not fenced: %+v", status)
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("composed controller did not observe the empty catalog: %+v", controller.Status())
}
