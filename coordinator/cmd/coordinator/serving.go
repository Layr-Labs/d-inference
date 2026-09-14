package main

import (
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/config"
)

func serverConfig(cfg *config.AppConfig, logger *slog.Logger) api.ServerConfig {
	// Provider/consumer IP geolocation (api.newProviderGeoResolverFromEnv, invoked
	// from NewServer) reads two optional env vars:
	//   - EIGENINFERENCE_TRUST_GEO_HEADERS=1 — trust CF/Vercel geo headers from a
	//     trusted reverse proxy instead of calling ip-api.com.
	//   - EIGENINFERENCE_IPAPI_KEY — ip-api.com PRO key (SECRET; inject via KMS /
	//     Secret Manager, never commit). When set, geo lookups use the unmetered
	//     https://pro.ip-api.com endpoint; unset falls back to the free, 45 req/min
	//     http://ip-api.com endpoint (graceful, so dev without a key still works).
	// Remote media resolution (mediafetch) is read and validated as part of
	// AppConfig; hand the validated value to the server instead of letting
	// NewServer re-read the environment.
	serverCfg := cfg.ServerConfig
	serverCfg.DurableTrustReuse = cfg.StoreConfig.DatabaseURL != ""
	serverCfg.MediaFetch = &cfg.MediaFetchCfg
	// LIVE first-content deadline base — distinct from the shadow evaluator's
	// base below. Validate and bind it to this Server instance before startup;
	// production sets 9000ms, while an unset/invalid value keeps the intentional
	// 5000ms ordinary-unit default. Exact model policy may tighten this base but
	// never loosen a lower operator value. Every request adds 1ms per prompt token.
	if v := os.Getenv("EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS"); v != "" {
		if base, ok := validateTTFTDeadlineBaseMs(v); ok {
			serverCfg.FirstContentDeadlineBase = time.Duration(base) * time.Millisecond
			logger.Warn("LIVE TTFT deadline base OVERRIDDEN via EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS (changes the HARD_REJECT cutoff)", "base_ms", base)
		} else {
			logger.Warn("invalid or out-of-range EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS; keeping default 5000",
				"value", v, "min_ms", minTTFTDeadlineBaseMs, "max_ms", maxTTFTDeadlineBaseMs)
		}
	}
	return serverCfg
}

func newHTTPServer(port string, handler http.Handler) *http.Server {
	// HTTP server with graceful shutdown.
	httpServer := &http.Server{
		Addr:    ":" + port,
		Handler: handler,
		// ReadHeaderTimeout bounds the request-header read phase independently of
		// the body, closing the slow-header (Slowloris) DoS window: a client that
		// trickles or never finishes its header block is dropped at 5s instead of
		// tying up a connection/goroutine. Kept shorter than ReadTimeout so header
		// hardening doesn't constrain legitimate (larger) request bodies.
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      0, // SSE streaming requires no write timeout
		IdleTimeout:       120 * time.Second,
		// MaxHeaderBytes caps per-connection header memory at 64 KB (Go's default
		// is 1 MB), bounding what an attacker can force the server to buffer for
		// headers and rejecting abusive oversized-header requests early.
		MaxHeaderBytes: 64 << 10,
	}
	return httpServer
}
