package registry_test

import (
	"bytes"
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	providerwrite "github.com/eigeninference/d-inference/coordinator/internal/registry/providerwrite"
)

// TestProviderWriterControlLaneHoldsCancelsBehindBlockedDataWrite pins the
// control-lane capacity that bounds silent cancel loss: while one data frame
// is stuck in its (non-preemptible) socket write, the lane must accept
// providerwrite.ControlQueueSize cancels, reject the next with
// providerwrite.ErrQueueFull, and drain every accepted one once the data
// write completes.
func TestProviderWriterControlLaneHoldsCancelsBehindBlockedDataWrite(t *testing.T) {
	if providerwrite.ControlQueueSize < 256 {
		t.Fatalf("providerControlQueueSize = %d, want >= 256 (control frames are ~100 B; a full lane drops a cancel)", providerwrite.ControlQueueSize)
	}
	release := make(chan struct{})
	dataStarted := make(chan struct{})
	var once sync.Once
	var frames atomic.Int32
	w := newWriterFixture(providerwrite.DataQueueSize, providerwrite.ControlQueueSize, nil, nil, func(data []byte) error {
		if bytes.Contains(data, []byte(`"lane":"data"`)) {
			once.Do(func() { close(dataStarted) })
			<-release
		}
		frames.Add(1)
		return nil
	}, nil)
	go w.Run()
	t.Cleanup(w.Close)

	dataErr := make(chan error, 1)
	go func() { dataErr <- w.Write(context.Background(), []byte(`{"lane":"data"}`)) }()
	select {
	case <-dataStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("data frame never reached the socket write")
	}

	for i := 0; i < providerwrite.ControlQueueSize; i++ {
		frame := []byte(fmt.Sprintf(`{"type":"cancel","request_id":"req-%d"}`, i))
		if err := w.Enqueue(context.Background(), frame); err != nil {
			t.Fatalf("enqueue #%d behind a blocked data write = %v, want nil", i, err)
		}
	}
	if err := w.Enqueue(context.Background(), []byte(`{"type":"cancel","request_id":"overflow"}`)); err != providerwrite.ErrQueueFull {
		t.Fatalf("enqueue #%d = %v, want errProviderWriterQueueFull", providerwrite.ControlQueueSize, err)
	}

	close(release)
	if err := <-dataErr; err != nil {
		t.Fatalf("data write = %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for frames.Load() < int32(providerwrite.ControlQueueSize+1) && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if got := frames.Load(); got != int32(providerwrite.ControlQueueSize+1) {
		t.Fatalf("frames written = %d, want %d (data + every accepted cancel)", got, providerwrite.ControlQueueSize+1)
	}
}
