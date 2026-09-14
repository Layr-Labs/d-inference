package registry

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestProviderWriterHandoffAllowsReentrantControlBeforeWire(t *testing.T) {
	serverConn, clientConn := testWebSocketPair(t)
	clientConn.SetReadLimit(-1)
	p := &Provider{Conn: serverConn, writer: newProviderWriter(serverConn)}
	t.Cleanup(p.closeWriterNow)
	payload := []byte(strings.Repeat("a", 512<<10))
	type readResult struct {
		first, second string
		err           error
	}
	received := make(chan readResult, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, first, err := clientConn.Read(ctx)
		if err != nil {
			received <- readResult{err: err}
			return
		}
		_, second, err := clientConn.Read(ctx)
		received <- readResult{first: string(first), second: string(second), err: err}
	}()
	var handedOff time.Time
	var enqueueErr error
	var providerLockAvailable bool
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	metadata, err := p.WriteTextDeferred(ctx, func(time.Time) ([]byte, error) { return payload, nil }, func(metadata TextFrameWriteMetadata) {
		providerLockAvailable = p.mu.TryLock()
		if !providerLockAvailable {
			return
		}
		handedOff = metadata.DequeuedAt
		p.mu.Unlock()
		result := make(chan error, 1)
		go func() { result <- p.EnqueueText(context.Background(), []byte(`{"type":"cancel"}`)) }()
		select {
		case enqueueErr = <-result:
		case <-time.After(2 * time.Second):
			enqueueErr = fmt.Errorf("reentrant enqueue waited on the handoff")
		}
	})
	if err != nil {
		t.Fatalf("deferred Provider write = %v", err)
	}
	if !providerLockAvailable {
		t.Fatal("Provider lock was held during submitting-owner handoff")
	}
	if handedOff.IsZero() || !handedOff.Equal(metadata.DequeuedAt) {
		t.Fatalf("handoff metadata = %v, returned = %v", handedOff, metadata.DequeuedAt)
	}
	if enqueueErr != nil {
		t.Fatalf("reentrant control enqueue = %v", enqueueErr)
	}
	select {
	case got := <-received:
		if got.err != nil {
			t.Fatalf("read Provider frames: %v", got.err)
		}
		if got.first != string(payload) {
			t.Fatal("deferred fragmented Provider frame changed or was overtaken")
		}
		if got.second != `{"type":"cancel"}` {
			t.Fatalf("control frame = %q", got.second)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Provider frames were not delivered")
	}
	p.closeWriterNow()
	if err := p.WriteText(context.Background(), []byte("after-close")); err != ErrProviderWriterStopped {
		t.Fatalf("write after Provider teardown = %v, want ErrProviderWriterStopped", err)
	}
}
