package providerwriter

import (
	"bytes"
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// TestProviderWriterControlLaneHoldsCancelsBehindBlockedDataWrite pins the
// control-lane capacity that bounds silent cancel loss: while one data frame
// is stuck in its (non-preemptible) socket write, the lane must accept
// controlQueueSize cancels, reject the next with
// errQueueFull, and drain every accepted one once the data
// write completes.
func TestProviderWriterControlLaneHoldsCancelsBehindBlockedDataWrite(t *testing.T) {
	if controlQueueSize < 256 {
		t.Fatalf("providerControlQueueSize = %d, want >= 256 (control frames are ~100 B; a full lane drops a cancel)", controlQueueSize)
	}
	release := make(chan struct{})
	dataStarted := make(chan struct{})
	var once sync.Once
	var frames atomic.Int32
	w := &Writer{
		queue:   make(chan *writeRequest, dataQueueSize),
		control: make(chan *writeRequest, controlQueueSize),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
		writeFrameForTest: func(data []byte) error {
			if bytes.Contains(data, []byte(`"lane":"data"`)) {
				once.Do(func() { close(dataStarted) })
				<-release
			}
			frames.Add(1)
			return nil
		},
	}
	go w.run()
	t.Cleanup(w.CloseNow)

	dataErr := make(chan error, 1)
	go func() { dataErr <- w.Write(context.Background(), []byte(`{"lane":"data"}`)) }()
	select {
	case <-dataStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("data frame never reached the socket write")
	}

	for i := 0; i < controlQueueSize; i++ {
		frame := []byte(fmt.Sprintf(`{"type":"cancel","request_id":"req-%d"}`, i))
		if err := w.Enqueue(context.Background(), frame); err != nil {
			t.Fatalf("enqueue #%d behind a blocked data write = %v, want nil", i, err)
		}
	}
	if err := w.Enqueue(context.Background(), []byte(`{"type":"cancel","request_id":"overflow"}`)); err != errQueueFull {
		t.Fatalf("enqueue #%d = %v, want errProviderWriterQueueFull", controlQueueSize, err)
	}

	close(release)
	if err := <-dataErr; err != nil {
		t.Fatalf("data write = %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for frames.Load() < int32(controlQueueSize+1) && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if got := frames.Load(); got != int32(controlQueueSize+1) {
		t.Fatalf("frames written = %d, want %d (data + every accepted cancel)", got, controlQueueSize+1)
	}
}
