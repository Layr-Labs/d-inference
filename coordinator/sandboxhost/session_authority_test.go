package sandboxhost

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestSandboxWriterQueueHonorsRequestDeadline(t *testing.T) {
	transport := &blockedSandboxTransport{started: make(chan struct{}), release: make(chan struct{})}
	registry := NewRegistry(nil)
	session, err := registry.Register(testHeader(protocol.SandboxTypeHostRegister, 1), testRegistration(), transport)
	if err != nil {
		t.Fatal(err)
	}
	defer close(transport.release)
	first := make(chan error, 1)
	go func() { first <- session.Send(context.Background(), protocol.SandboxTypeDrain, struct{}{}) }()
	select {
	case <-transport.started:
	case <-time.After(time.Second):
		t.Fatal("first writer did not start")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	second := make(chan error, 1)
	go func() { second <- session.Send(ctx, protocol.SandboxTypeDrain, struct{}{}) }()
	select {
	case err := <-second:
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("queued writer error=%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("queued writer ignored its deadline")
	}
	if session.Snapshot().NextOutbound != 2 {
		t.Fatal("cancelled queued send consumed sequence authority")
	}
}

func TestSandboxDisconnectCancelsActiveTransportWrite(t *testing.T) {
	transport := &blockedSandboxTransport{started: make(chan struct{}), release: make(chan struct{})}
	registry := NewRegistry(nil)
	session, err := registry.Register(testHeader(protocol.SandboxTypeHostRegister, 1), testRegistration(), transport)
	if err != nil {
		t.Fatal(err)
	}
	defer close(transport.release)
	done := make(chan error, 1)
	go func() { done <- session.Send(context.Background(), protocol.SandboxTypeDrain, struct{}{}) }()
	select {
	case <-transport.started:
	case <-time.After(time.Second):
		t.Fatal("write never started")
	}
	registry.Disconnect(session)
	select {
	case err := <-done:
		if !errors.Is(err, ErrSessionClosed) {
			t.Fatalf("disconnected write error=%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("disconnected writer retained transient file bytes")
	}
}

type blockedSandboxTransport struct{ started, release chan struct{} }

func (t *blockedSandboxTransport) Write(ctx context.Context, _ []byte) error {
	close(t.started)
	select {
	case <-t.release:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
func (t *blockedSandboxTransport) Close(string) error { return nil }
