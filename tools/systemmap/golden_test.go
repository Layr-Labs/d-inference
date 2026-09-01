package main

import "testing"

// TestCoordinatorMapHasNoDrift is this repository's own drift regression: the real
// coordinator source must still be fully explained by the committed overlay, and
// the map it produces must render. Nothing is written — the artifact is generated
// by CI, never committed — so this asserts the only thing that can rot: the
// curated half falling behind the code.
//
// This is the same assertion the System Map job makes, so a change that outgrows
// the overlay fails in `go test` before it fails in the workflow.
func TestCoordinatorMapHasNoDrift(t *testing.T) {
	if testing.Short() {
		t.Skip("type-checks the whole coordinator")
	}
	if err := run("", defaultModule, defaultOverlay, defaultOut, fixtureRevision, true, true); err != nil {
		t.Fatalf("%v\n\ninspect with: make -C tools/systemmap", err)
	}
}
