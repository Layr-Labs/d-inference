package policy

import (
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// maxRedirects bounds redirect-chain depth. Every hop is re-validated (scheme,
// userinfo, blocklist) and every dial is IP-checked by the Control hook, so this
// only needs to stop loops / unbounded chains.
const maxRedirects = 3

// newHTTPClient builds the dedicated, hardened http.Client used for media
// fetches. It is isolated from the coordinator's other outbound clients (small
// connection pool) so a media-fetch storm can't starve provider/registry traffic.
func NewHTTPClient(cfg Config) *http.Client {
	dialer := &net.Dialer{
		Timeout:   cfg.FetchTimeout,
		KeepAlive: -1, // no keep-alive: each fetch is one-shot
		Control:   dialControl(cfg.AllowPrivateIPs),
	}
	transport := &http.Transport{
		DialContext:        dialer.DialContext,
		DisableKeepAlives:  true,
		DisableCompression: true, // never auto-inflate: defeats gzip/zip bombs
		ForceAttemptHTTP2:  false,
		MaxIdleConns:       cfg.GlobalConcurrency,
		// PROCESS-WIDE, not per-request: this client is built once per Resolver,
		// so MaxConnsPerHost bounds every concurrent fetch to a given origin
		// across ALL requests. Concurrency is the per-REQUEST worker-pool size
		// (4) — using it here would serialize a media-heavy fleet into waves of
		// four sockets per CDN, and because DisableKeepAlives means no connection
		// is ever reused, the queue wait is charged against FetchTimeout and
		// healthy origins start returning spurious media_fetch_timeout. The
		// process-wide socket bound belongs to GlobalConcurrency, which is
		// exactly what globalSem already admits.
		MaxConnsPerHost: cfg.GlobalConcurrency,
		// Headers are read before any body budget applies, and Go's default cap is
		// 10 MiB per connection — with GlobalConcurrency slots an attacker-owned
		// origin could force GlobalConcurrency x 10 MiB of header buffering while
		// every body stayed tightly capped. No legitimate media origin needs more
		// than a few KiB of headers.
		MaxResponseHeaderBytes: 64 << 10,
		TLSHandshakeTimeout:    cfg.FetchTimeout,
		ResponseHeaderTimeout:  cfg.FetchTimeout,
		ExpectContinueTimeout:  time.Second,
	}
	return &http.Client{
		Transport:     transport,
		Timeout:       cfg.FetchTimeout,
		CheckRedirect: RedirectGuard(cfg),
	}
}

// redirectGuard validates each redirect hop: scheme allowlist, no transport
// downgrade, no embedded credentials, and the optional domain blocklist. The IP
// of every hop is still validated independently by the dialer Control hook.
// Depth is capped.
func RedirectGuard(cfg Config) func(req *http.Request, via []*http.Request) error {
	return func(req *http.Request, via []*http.Request) error {
		// Strip the Referer Go's client auto-populates from the previous hop.
		// The previous URL can be a presigned S3/R2/GCS link whose query string
		// carries the signature; without this a cross-host redirect would leak
		// that signed URL to the redirect target, defeating the URL-secrecy the
		// rest of this package preserves.
		req.Header.Del("Referer")
		if len(via) >= maxRedirects {
			return fmt.Errorf("%w: too many redirects (>%d)", ErrBlockedHost, maxRedirects)
		}
		// Refuse an https -> http downgrade. Validating each hop independently
		// against the scheme allowlist would accept it: both schemes are allowed
		// in isolation. But a caller who supplied an https URL is owed transport
		// confidentiality and integrity for the whole chain — otherwise a
		// redirect's signed query crosses the network in plaintext, and an
		// on-path party can swap the image before it is inlined into the
		// (encrypted) provider request. A plain http URL supplied deliberately
		// still works; only the downgrade is refused.
		if strings.EqualFold(req.URL.Scheme, "http") {
			for _, prev := range via {
				if strings.EqualFold(prev.URL.Scheme, "https") {
					return fmt.Errorf("%w: https to http redirect downgrade", ErrBlockedScheme)
				}
			}
		}
		return ValidateURL(req.URL, cfg)
	}
}

// validateURL enforces the scheme + port allowlists, rejects embedded userinfo,
// and applies the domain blocklist. IP-level SSRF is enforced at dial time.
func ValidateURL(u *url.URL, cfg Config) error {
	scheme := strings.ToLower(u.Scheme)
	if scheme != "http" && scheme != "https" {
		return fmt.Errorf("%w: %q (only http/https)", ErrBlockedScheme, u.Scheme)
	}
	if u.User != nil {
		return fmt.Errorf("%w: embedded credentials are not allowed", ErrBlockedHost)
	}
	if u.Host == "" {
		return fmt.Errorf("%w: empty host", ErrBlockedHost)
	}
	if !cfg.AllowNonStandardPorts {
		port := u.Port()
		if (scheme == "http" && port != "" && port != "80") ||
			(scheme == "https" && port != "" && port != "443") {
			return fmt.Errorf("%w: non-standard %s port %q is not allowed", ErrBlockedHost, scheme, port)
		}
	}
	return HostAllowed(u.Host, cfg.BlocklistDomains)
}

// isRemoteMediaURL reports whether s is an http(s) URL (as opposed to an inline
// data: URI, which is passed through untouched, or some other scheme).
func IsRemoteURL(s string) bool {
	t := strings.TrimSpace(s)
	if len(t) < 7 {
		return false
	}
	if strings.EqualFold(t[:7], "http://") {
		return true
	}
	return len(t) >= 8 && strings.EqualFold(t[:8], "https://")
}
