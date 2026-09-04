package saferun

import (
	"bytes"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// syncBuffer is a bytes.Buffer safe for concurrent Write/String. The stock
// bytes.Buffer isn't; slog.Logger can write to it from the recovering
// goroutine while the test reads from the main goroutine.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// waitForLog polls until the buffer contains substr or the deadline expires.
func waitForLog(buf *syncBuffer, substr string, deadline time.Duration) bool {
	end := time.Now().Add(deadline)
	for time.Now().Before(end) {
		if strings.Contains(buf.String(), substr) {
			return true
		}
		time.Sleep(2 * time.Millisecond)
	}
	return strings.Contains(buf.String(), substr)
}

// A panic inside a goroutine started with Go must be contained: the
// surrounding code continues to run and the panic is logged.
func TestGoRecoversPanic(t *testing.T) {
	buf := &syncBuffer{}
	logger := slog.New(slog.NewTextHandler(buf, nil))

	Go(logger, "test-panic", func() {
		panic("boom")
	})

	if !waitForLog(buf, "panic in goroutine", time.Second) {
		t.Fatalf("expected panic log, got: %s", buf.String())
	}
	logged := buf.String()
	if !strings.Contains(logged, "goroutine=test-panic") {
		t.Fatalf("expected goroutine name in log, got: %s", logged)
	}
	if !strings.Contains(logged, "boom") {
		t.Fatalf("expected panic message in log, got: %s", logged)
	}
}

// A normal (non-panicking) goroutine should complete silently.
func TestGoNoPanicNoLog(t *testing.T) {
	buf := &syncBuffer{}
	logger := slog.New(slog.NewTextHandler(buf, nil))

	done := make(chan struct{})
	Go(logger, "test-ok", func() {
		close(done)
	})
	<-done
	// Give the outer goroutine a chance to finish. We expect no log.
	time.Sleep(20 * time.Millisecond)

	if strings.Contains(buf.String(), "panic") {
		t.Fatalf("unexpected panic log: %s", buf.String())
	}
}

// Recover is a no-op when called outside an active panic.
func TestRecoverNoPanic(t *testing.T) {
	buf := &syncBuffer{}
	logger := slog.New(slog.NewTextHandler(buf, nil))

	func() {
		defer Recover(logger, "test-nop")
	}()

	if buf.String() != "" {
		t.Fatalf("expected no log output, got: %s", buf.String())
	}
}

// A nil logger must not crash — Recover degrades gracefully.
func TestRecoverNilLogger(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("Recover panicked with nil logger: %v", r)
		}
	}()
	func() {
		defer Recover(nil, "test-nil")
		panic("should be swallowed")
	}()
}

// Report logs a value the caller recovered itself, so callers that need the
// panic as a return value get the same log line and observer notification.
func TestReportLogsRecoveredValue(t *testing.T) {
	buf := &syncBuffer{}
	logger := slog.New(slog.NewTextHandler(buf, nil))
	var observed atomic.Int32
	SetPanicObserver(func(string) { observed.Add(1) })
	defer SetPanicObserver(nil)

	var got any
	func() {
		defer func() {
			got = recover()
			Report(logger, "test-report", got)
		}()
		panic("kaboom")
	}()
	if got != "kaboom" {
		t.Fatalf("recovered %v, want kaboom", got)
	}
	logged := buf.String()
	for _, want := range []string{"panic in goroutine", "goroutine=test-report", "kaboom", "stack="} {
		if !strings.Contains(logged, want) {
			t.Fatalf("log missing %q: %s", want, logged)
		}
	}
	if observed.Load() != 1 {
		t.Fatalf("observer calls = %d, want 1", observed.Load())
	}

	Report(logger, "test-nil", nil)
	if strings.Count(buf.String(), "panic in goroutine") != 1 || observed.Load() != 1 {
		t.Fatalf("Report(nil) logged or observed: %s", buf.String())
	}
}
