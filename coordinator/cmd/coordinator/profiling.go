package main

import (
	"log/slog"
	"net"
	"net/http"
	"net/http/pprof"
	"os"
	"runtime"
	"time"
)

func configureProfiling(logger *slog.Logger) {
	// Optional pprof listener on a DEDICATED private mux/port — never the
	// public mux. The 2026-09-01 collapse was diagnosed blind because the
	// binary shipped without pprof (GET /debug/pprof/ = 404). Unset = nothing
	// listens.
	if addr := os.Getenv("EIGENINFERENCE_PPROF_ADDR"); addr != "" {
		if ln, err := startPprofListener(addr); err != nil {
			logger.Error("pprof listener failed to start", "addr", addr, "error", err)
		} else {
			enableContentionProfiling()
			logger.Warn("pprof debug listener ENABLED via EIGENINFERENCE_PPROF_ADDR — profiling data is sensitive; keep this address private (bind loopback / firewall it)",
				"addr", ln.Addr().String())
		}
	}
}

// enableContentionProfiling turns on the runtime's mutex and block profiles,
// which are off by default, so /debug/pprof/mutex and /debug/pprof/block on
// the pprof listener stop coming back empty. Sampling one in every hundred
// mutex contention events and an average of one blocking event per 1 ms
// spent blocked bounds the sampling overhead. Called only together with the env-gated listener.
func enableContentionProfiling() {
	runtime.SetMutexProfileFraction(100)
	runtime.SetBlockProfileRate(1_000_000)
}

// startPprofListener starts net/http/pprof on a DEDICATED mux bound to addr
// (EIGENINFERENCE_PPROF_ADDR, e.g. "127.0.0.1:6060") and serves it on its own
// listener — the public mux never gains /debug/pprof/ routes. An empty addr
// never reaches here (the caller gates on the env var), so nothing listens by
// default. The 2026-09-01 congestion collapse had to be diagnosed without any
// profiler (GET /debug/pprof/ = 404 on the running binary); this closes that
// gap without exposing profiles publicly.
func startPprofListener(addr string) (net.Listener, error) {
	mux := http.NewServeMux()
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	server := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		// The listener lives for the whole process; Serve only returns on a
		// listener error, which is not worth crashing the coordinator over.
		_ = server.Serve(ln)
	}()
	return ln, nil
}
