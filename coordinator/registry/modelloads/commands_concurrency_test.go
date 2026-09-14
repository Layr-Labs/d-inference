package modelloads

import (
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCommandsReserveOneModelPerSessionConcurrently(t *testing.T) {
	commands := NewCommands()
	now := time.Now()
	var accepted atomic.Int64
	var winningModel atomic.Value
	var workers sync.WaitGroup
	for i := 0; i < 32; i++ {
		workers.Add(1)
		go func(i int) {
			defer workers.Done()
			model := fmt.Sprintf("model-%d", i)
			if commands.Reserve("session", model, now) {
				accepted.Add(1)
				winningModel.Store(model)
			}
		}(i)
	}
	workers.Wait()
	if accepted.Load() != 1 {
		t.Fatalf("reserved %d models for one session", accepted.Load())
	}
	model := winningModel.Load().(string)
	commands.Backoff("session", model, MemoryBackoff)
	if started := commands.Complete("session", model); !started.Equal(now) {
		t.Fatalf("backoff changed original start: %v, want %v", started, now)
	}
	if status := commands.Observe("session", model); status.Pending || status.Started {
		t.Fatalf("terminal retained coupled command state: %+v", status)
	}
	if !commands.Reserve("session", "replacement", now) {
		t.Fatal("terminal did not release the session for another model")
	}
}
