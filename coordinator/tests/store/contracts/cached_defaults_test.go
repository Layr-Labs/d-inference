package store_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestZeroConfigCacheStoresUsers(t *testing.T) {
	c := store.NewCached(memory.NewMemory(store.Config{}), store.CacheConfig{})
	seedUser(t, c, "acct-1")
	if _, err := c.GetUserByAccountID("acct-1"); err != nil {
		t.Fatal(err)
	}
	if c.Stats().Users.Entries != 1 {
		t.Fatal("zero-config cache did not store")
	}
}
