// Package saferun provides a panic-safe goroutine wrapper for long-lived
// background tasks. A bare `go func()` without recover will take down the
// entire coordinator process if the task panics, killing every in-flight
// request from every connected consumer.
package saferun

import (
	"fmt"
	"log/slog"
	"runtime/debug"
	"sync/atomic"
)

// Go runs fn in a new goroutine with a deferred recover that logs any panic
// via logger and prevents it from propagating. Use this for long-lived or
// untrusted goroutines (per-connection read loops, background persisters,
// external RPC callers, tickers) so one bad input doesn't crash the process.
//
// name is used as a log field so operators can tell which goroutine panicked.
func Go(logger *slog.Logger, name string, fn func()) {
	go func() {
		defer Recover(logger, name)
		fn()
	}()
}

// Recover logs any in-flight panic with a stack trace. Call it as the first
// statement of a goroutine via `defer Recover(...)`. No-op if there is no
// active panic. Also notifies any registered observer (used to wire a
// Prometheus counter without taking a metrics import in this package —
// import direction must stay one-way).
func Recover(logger *slog.Logger, name string) {
	r := recover()
	if r == nil {
		return
	}
	if logger != nil {
		logger.Error("panic in goroutine",
			"goroutine", name,
			"panic", fmt.Sprintf("%v", r),
			"stack", string(debug.Stack()),
		)
	}
	if obs := observer.Load(); obs != nil {
		(*obs)(name)
	}
}

// PanicObserver is called once per recovered panic, after logging. The
// metrics package wires this up at startup to increment a Prometheus
// counter. Kept here as a function variable so saferun doesn't take a
// build-time dependency on metrics (which would create a cycle if metrics
// ever needed saferun).
type PanicObserver func(goroutineName string)

// observer is loaded under atomic semantics so concurrent Recover and
// SetPanicObserver calls don't race. atomic.Pointer is the simplest
// type-safe shape for a swappable function pointer in modern Go.
var observer atomic.Pointer[PanicObserver]

// SetPanicObserver registers (or clears) the observer. Pass nil to
// clear. Safe to call concurrently with Recover.
func SetPanicObserver(fn PanicObserver) {
	if fn == nil {
		observer.Store(nil)
		return
	}
	observer.Store(&fn)
}
