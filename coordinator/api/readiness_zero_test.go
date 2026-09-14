package api

import (
	"context"
	"testing"
)

func TestReadinessZeroServerKeepsLifecycleAccess(t *testing.T) {
	var srv Server
	if srv.IsDraining() || srv.Inflight() != 0 || !srv.WaitForInflightZero(context.Background()) {
		t.Fatal("zero server is not initially ready with no in-flight work")
	}
	srv.SetDraining(true)
	if !srv.IsDraining() || srv.Inflight() != 0 {
		t.Fatal("zero server did not enter drain")
	}
	srv.SetDraining(false)
	if srv.IsDraining() {
		t.Fatal("zero server did not leave drain")
	}
}
