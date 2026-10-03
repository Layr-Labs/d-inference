package memory

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func storeBackends(t *testing.T) map[string]store.Store {
	t.Helper()
	return map[string]store.Store{"memory": NewMemory(store.Config{})}
}
