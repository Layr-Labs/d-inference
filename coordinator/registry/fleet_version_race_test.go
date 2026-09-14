package registry

import (
	"sync"
	"testing"
)

func TestProviderCountByVersionConcurrentUpdate(t *testing.T) {
	reg := New(testLogger())
	provider := reg.Register("versioned", nil, testRegisterMessage())
	provider.SetVersion("old")
	var updates sync.WaitGroup
	updates.Add(1)
	go func() {
		defer updates.Done()
		for i := 0; i < 1000; i++ {
			provider.SetVersion("new")
			provider.SetVersion("old")
		}
	}()
	defer updates.Wait()
	for i := 0; i < 1000; i++ {
		counts := reg.ProviderCountByVersion()
		if counts["old"]+counts["new"] != 1 || len(counts) != 1 {
			t.Fatalf("one connected provider must appear exactly once: %v", counts)
		}
	}
}
