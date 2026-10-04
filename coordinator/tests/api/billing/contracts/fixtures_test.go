package billing_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func stripeSessionServer(t *testing.T) (*api.Server, *memory.MemoryStore) {
	t.Helper()
	f, st := stripePayoutsTestServer(t, true, nil)
	return f.Server, st
}
