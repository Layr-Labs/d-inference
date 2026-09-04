package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	envTrustGeoHeaders = "EIGENINFERENCE_TRUST_GEO_HEADERS"
	// envIPAPIKey holds the ip-api.com PRO API key. It is a SECRET — injected via
	// the deployment environment / GCP Secret Manager, never committed.
	// When set, geo lookups use the unmetered https://pro.ip-api.com endpoint;
	// when empty the resolver falls back to the free http://ip-api.com tier.
	envIPAPIKey = "EIGENINFERENCE_IPAPI_KEY"

	// ipAPIFreeBaseURL is the free, HTTP-only ip-api.com endpoint (45 req/min by
	// source IP, no key). ipAPIProBaseURL is the keyed, HTTPS, unmetered PRO
	// endpoint. Both share the same /json/<ip> path and field set.
	ipAPIFreeBaseURL = "http://ip-api.com"
	ipAPIProBaseURL  = "https://pro.ip-api.com"

	// ipAPIFields is the comma-separated ip-api.com field selector. Kept minimal:
	// only the geo fields ProviderLocation needs, plus status for success checks.
	ipAPIFields = "status,country,countryCode,regionName,region,city,lat,lon,timezone"

	// geoLookupTimeout bounds one ip-api.com round trip. Only the synchronous
	// provider-registration path ever waits on it; consumer requests go through
	// LookupAsync and never block on the network.
	geoLookupTimeout = 3 * time.Second
	// geoCacheMaxEntries bounds the per-IP cache (random eviction when full).
	// OpenRouter and the other wholesale channels arrive from a handful of
	// egress IPs, so steady-state occupancy is tiny; the bound only matters
	// under an IP-diverse scan.
	geoCacheMaxEntries = 10_000
	// geoCachePositiveTTL is how long a resolved location is reused;
	// geoCacheNegativeTTL is how long a failed/unknown lookup is remembered so
	// a degraded ip-api does not get one round trip per request.
	geoCachePositiveTTL = time.Hour
	geoCacheNegativeTTL = 5 * time.Minute
	// geoLookupMaxInflight caps concurrent background fills so an IP-diverse
	// request burst cannot fan out into unbounded goroutines / sockets; misses
	// past the cap are dropped (the next request from that IP retries).
	geoLookupMaxInflight = 64
)

// providerGeoResolver resolves the approximate location of an HTTP request's
// client. Lookup blocks on the network (once per provider WebSocket connect);
// LookupAsync never does (once per consumer inference request) — it serves
// the per-IP cache and fills misses in the background.
type providerGeoResolver interface {
	Lookup(*http.Request) *store.ProviderLocation
	LookupAsync(*http.Request) *store.ProviderLocation
}

// geoCacheEntry is one cached lookup; a nil loc is a negative entry (the
// lookup failed or ip-api answered with a non-success status).
type geoCacheEntry struct {
	loc *store.ProviderLocation
	at  time.Time
}

type ipAPIGeoResolver struct {
	trustHeaders bool
	// apiKey is the ip-api.com PRO key (empty => free tier). When non-empty the
	// resolver targets baseURL=ipAPIProBaseURL and appends &key=<apiKey>.
	apiKey string
	// baseURL is the ip-api.com origin (scheme+host, no trailing slash). Defaults
	// to the free or PRO endpoint based on apiKey; overridable in tests so URL
	// construction and response parsing can be exercised against httptest without
	// hitting the live service.
	baseURL string
	// httpClient performs the lookup. Production uses a dedicated client (own
	// idle-connection pool, request timeout); overridable in tests. A nil client
	// falls back to http.DefaultClient at call time.
	httpClient *http.Client
	logger     *slog.Logger
	// now is the cache clock (nil => time.Now); tests inject a fake clock to
	// exercise TTL expiry without sleeping.
	now func() time.Time

	// mu guards cache and inflight. Both are lazily allocated so resolvers
	// built as struct literals (tests) work without a constructor.
	mu       sync.Mutex
	cache    map[string]geoCacheEntry
	inflight map[string]struct{}

	// networkLookups counts ip-api round trips (sync and async); asyncDropped
	// counts misses not filled because geoLookupMaxInflight was reached.
	networkLookups atomic.Uint64
	asyncDropped   atomic.Uint64
}

func newProviderGeoResolverFromEnv(logger *slog.Logger) providerGeoResolver {
	trustHeaders := os.Getenv(envTrustGeoHeaders) == "1"
	apiKey := strings.TrimSpace(os.Getenv(envIPAPIKey))
	baseURL := ipAPIFreeBaseURL
	if apiKey != "" {
		baseURL = ipAPIProBaseURL
	}
	return &ipAPIGeoResolver{
		trustHeaders: trustHeaders,
		apiKey:       apiKey,
		baseURL:      baseURL,
		httpClient:   newGeoHTTPClient(),
		logger:       logger,
	}
}

// newGeoHTTPClient builds the resolver's own client: http.DefaultTransport
// keeps only 2 idle connections per host, so sharing http.DefaultClient meant
// a fresh TLS handshake to pro.ip-api.com on most lookups. A dedicated
// transport with a deeper idle pool keeps the (now background) fills cheap,
// and the client-level timeout bounds every round trip even when a caller
// forgets the context deadline.
func newGeoHTTPClient() *http.Client {
	transport, ok := http.DefaultTransport.(*http.Transport)
	if !ok {
		return &http.Client{Timeout: geoLookupTimeout}
	}
	t := transport.Clone()
	t.MaxIdleConnsPerHost = 8
	return &http.Client{Timeout: geoLookupTimeout, Transport: t}
}

func (g *ipAPIGeoResolver) clock() time.Time {
	if g.now != nil {
		return g.now()
	}
	return time.Now()
}

// headerLocation is the trusted-proxy shortcut: behind a proxy that sets geo
// headers (Cloudflare, Vercel) the answer is already on the request and no
// lookup — cached or not — is needed.
func (g *ipAPIGeoResolver) headerLocation(r *http.Request) *store.ProviderLocation {
	if !g.trustHeaders {
		return nil
	}
	remoteIP := parseIPHost(r.RemoteAddr)
	if remoteIP == nil || !trustedProxyIP(remoteIP) {
		return nil
	}
	return locationFromTrustedGeoHeaders(r)
}

// lookupIP extracts the client's public IP, or nil when there is nothing an
// external geo service could resolve (private, loopback, unparseable).
func lookupIP(r *http.Request) net.IP {
	ip := providerClientIP(r)
	if ip == nil || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() {
		return nil
	}
	return ip
}

// Lookup resolves synchronously: header shortcut, then the per-IP cache, then
// one ip-api round trip whose result (nil included) populates the cache. Used
// by provider registration, which runs once per WebSocket connect and stores
// the location on the Provider record.
func (g *ipAPIGeoResolver) Lookup(r *http.Request) *store.ProviderLocation {
	if g == nil || r == nil {
		return nil
	}
	if loc := g.headerLocation(r); loc != nil {
		return loc
	}
	ip := lookupIP(r)
	if ip == nil {
		return nil
	}
	key := ip.String()
	if loc, ok := g.cached(key); ok {
		return loc
	}
	loc := g.lookupIPAPI(ip)
	g.storeResult(key, loc)
	return cloneLocation(loc)
}

// LookupAsync is the consumer-request path: it never waits on the network.
// A cache hit (positive or negative) answers immediately; a miss schedules one
// background fill per IP (deduplicated while in flight, bounded fleet-wide by
// geoLookupMaxInflight) and returns nil, so the first request from an IP per
// TTL carries no location — telemetry-only, never routing or billing.
func (g *ipAPIGeoResolver) LookupAsync(r *http.Request) *store.ProviderLocation {
	if g == nil || r == nil {
		return nil
	}
	if loc := g.headerLocation(r); loc != nil {
		return loc
	}
	ip := lookupIP(r)
	if ip == nil {
		return nil
	}
	key := ip.String()
	if loc, ok := g.cached(key); ok {
		return loc
	}
	g.mu.Lock()
	if g.inflight == nil {
		g.inflight = make(map[string]struct{})
	}
	if _, busy := g.inflight[key]; busy {
		g.mu.Unlock()
		return nil
	}
	if len(g.inflight) >= geoLookupMaxInflight {
		g.mu.Unlock()
		g.asyncDropped.Add(1)
		return nil
	}
	g.inflight[key] = struct{}{}
	g.mu.Unlock()

	saferun.Go(g.logger, "geo_lookup", func() {
		loc := g.lookupIPAPI(ip)
		g.storeResult(key, loc)
		g.mu.Lock()
		delete(g.inflight, key)
		g.mu.Unlock()
	})
	return nil
}

// cached returns a copy of the cached location for key and whether the entry
// is live. Negative entries hit too (ok=true, nil location) so a failing
// lookup is retried at most once per geoCacheNegativeTTL. Expired entries are
// dropped on read.
func (g *ipAPIGeoResolver) cached(key string) (*store.ProviderLocation, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	entry, ok := g.cache[key]
	if !ok {
		return nil, false
	}
	ttl := geoCachePositiveTTL
	if entry.loc == nil {
		ttl = geoCacheNegativeTTL
	}
	if g.clock().Sub(entry.at) >= ttl {
		delete(g.cache, key)
		return nil, false
	}
	return cloneLocation(entry.loc), true
}

// storeResult records a lookup result (nil = negative), evicting one random
// entry when the cache is full. Map iteration order is random in Go, so the
// first ranged key is a uniformly-random victim without any bookkeeping.
func (g *ipAPIGeoResolver) storeResult(key string, loc *store.ProviderLocation) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.cache == nil {
		g.cache = make(map[string]geoCacheEntry)
	}
	if _, present := g.cache[key]; !present && len(g.cache) >= geoCacheMaxEntries {
		for victim := range g.cache {
			delete(g.cache, victim)
			break
		}
	}
	g.cache[key] = geoCacheEntry{loc: cloneLocation(loc), at: g.clock()}
}

// cacheLen reports the number of cached IPs (tests / diagnostics).
func (g *ipAPIGeoResolver) cacheLen() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.cache)
}

func cloneLocation(loc *store.ProviderLocation) *store.ProviderLocation {
	if loc == nil {
		return nil
	}
	cp := *loc
	return &cp
}

// lookupIPAPI resolves geolocation via ip-api.com with one blocking round trip.
//
// With a PRO key (EIGENINFERENCE_IPAPI_KEY) it uses the unmetered
// https://pro.ip-api.com endpoint; without one it falls back to the free
// http://ip-api.com endpoint (45 req/min by source IP). Callers go through the
// per-IP cache, so the free tier sees at most one request per client IP per
// TTL rather than one per inference request or provider connect. The Source
// field records which tier answered ("ip-api-pro" vs "ip-api").
func (g *ipAPIGeoResolver) lookupIPAPI(ip net.IP) *store.ProviderLocation {
	g.networkLookups.Add(1)
	ctx, cancel := context.WithTimeout(context.Background(), geoLookupTimeout)
	defer cancel()

	apiURL := g.buildLookupURL(ip)
	req, err := http.NewRequestWithContext(ctx, "GET", apiURL, nil)
	if err != nil {
		return nil
	}
	client := g.httpClient
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		if g.logger != nil {
			// A *url.Error's text embeds the request URL, which on the PRO tier
			// carries ?key=<secret>: log only the underlying transport error.
			g.logger.Debug("ip-api lookup failed", "ip", ip.String(), "pro", g.apiKey != "", "error", redactLookupError(err))
		}
		return nil
	}
	defer resp.Body.Close()

	var result struct {
		Status      string  `json:"status"`
		Country     string  `json:"country"`
		CountryCode string  `json:"countryCode"`
		RegionName  string  `json:"regionName"`
		Region      string  `json:"region"`
		City        string  `json:"city"`
		Lat         float64 `json:"lat"`
		Lon         float64 `json:"lon"`
		Timezone    string  `json:"timezone"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil || result.Status != "success" {
		if g.logger != nil {
			g.logger.Debug("ip-api lookup unsuccessful", "ip", ip.String(), "pro", g.apiKey != "", "status", result.Status)
		}
		return nil
	}

	return &store.ProviderLocation{
		City:        result.City,
		Region:      result.RegionName,
		RegionCode:  result.Region,
		Country:     result.Country,
		CountryCode: strings.ToUpper(result.CountryCode),
		Latitude:    result.Lat,
		Longitude:   result.Lon,
		Timezone:    result.Timezone,
		Source:      g.sourceLabel(),
		UpdatedAt:   time.Now().UTC(),
	}
}

// redactLookupError strips the request URL from a client error so the keyed
// PRO URL never reaches a log line; other errors pass through unchanged.
func redactLookupError(err error) error {
	var urlErr *url.Error
	if errors.As(err, &urlErr) && urlErr.Err != nil {
		return urlErr.Err
	}
	return err
}

// buildLookupURL constructs the ip-api.com request URL for ip. When a PRO key is
// configured it targets baseURL (https://pro.ip-api.com by default) and appends
// &key=<key>; otherwise it uses the free endpoint with no key. The /json/<ip>
// path and field set are identical across tiers, so the only wire difference is
// the origin and the trailing key parameter.
func (g *ipAPIGeoResolver) buildLookupURL(ip net.IP) string {
	base := strings.TrimRight(g.baseURL, "/")
	if base == "" {
		base = ipAPIFreeBaseURL
	}
	apiURL := fmt.Sprintf("%s/json/%s?fields=%s", base, ip.String(), ipAPIFields)
	if g.apiKey != "" {
		apiURL += "&key=" + url.QueryEscape(g.apiKey)
	}
	return apiURL
}

// sourceLabel reports the ProviderLocation.Source tag for the active tier so
// telemetry can distinguish PRO from free lookups.
func (g *ipAPIGeoResolver) sourceLabel() string {
	if g.apiKey != "" {
		return "ip-api-pro"
	}
	return "ip-api"
}

// requestLocation resolves the consumer's approximate location for the usage
// row (telemetry only — never routing or billing). It runs on the inference
// request goroutine, so it takes the non-blocking path: a cache miss returns
// nil for this request and fills in the background for the next one.
func (s *Server) requestLocation(r *http.Request) *store.ProviderLocation {
	if s == nil || s.geoResolver == nil || r == nil {
		return nil
	}
	loc := s.geoResolver.LookupAsync(r)
	if loc == nil {
		return nil
	}
	cp := *loc
	if cp.Source != "" {
		cp.Source = "request_" + cp.Source
	}
	return &cp
}

func providerClientIP(r *http.Request) net.IP {
	remoteIP := parseIPHost(r.RemoteAddr)
	if remoteIP != nil && trustedProxyIP(remoteIP) {
		if ip := forwardedClientIP(r); ip != nil {
			return ip
		}
	}
	return remoteIP
}

func forwardedClientIP(r *http.Request) net.IP {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.Split(xff, ",")
		var fallback net.IP
		for i := len(parts) - 1; i >= 0; i-- {
			part := parts[i]
			if ip := net.ParseIP(strings.TrimSpace(part)); ip != nil {
				fallback = ip
				if !trustedProxyIP(ip) {
					return ip
				}
			}
		}
		return fallback
	}
	if xrip := r.Header.Get("X-Real-IP"); xrip != "" {
		if ip := net.ParseIP(strings.TrimSpace(xrip)); ip != nil {
			return ip
		}
	}
	if forwarded := r.Header.Get("Forwarded"); forwarded != "" {
		var fallback net.IP
		entries := strings.Split(forwarded, ",")
		for i := len(entries) - 1; i >= 0; i-- {
			for _, part := range strings.Split(entries[i], ";") {
				k, v, ok := strings.Cut(strings.TrimSpace(part), "=")
				if !ok || !strings.EqualFold(k, "for") {
					continue
				}
				v = strings.Trim(v, "\"")
				if host, _, err := net.SplitHostPort(v); err == nil {
					v = host
				}
				v = strings.Trim(v, "[]")
				if ip := net.ParseIP(v); ip != nil {
					fallback = ip
					if !trustedProxyIP(ip) {
						return ip
					}
				}
			}
		}
		return fallback
	}
	return nil
}

func parseIPHost(hostport string) net.IP {
	host := hostport
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		host = h
	}
	return net.ParseIP(strings.Trim(host, "[]"))
}

func trustedProxyIP(ip net.IP) bool {
	if ip == nil {
		return false
	}
	return ip.IsLoopback() || ip.IsPrivate()
}

func locationFromTrustedGeoHeaders(r *http.Request) *store.ProviderLocation {
	countryCode := firstHeader(r,
		"CF-IPCountry",
		"X-Vercel-IP-Country",
		"X-Geo-Country",
	)
	if countryCode == "" || countryCode == "XX" {
		return nil
	}

	loc := &store.ProviderLocation{
		City:        headerLocationValue(firstHeader(r, "CF-IPCity", "X-Vercel-IP-City", "X-Geo-City")),
		Region:      headerLocationValue(firstHeader(r, "CF-IPRegion", "X-Vercel-IP-Country-Region", "X-Geo-Region")),
		RegionCode:  headerLocationValue(firstHeader(r, "CF-Region-Code", "X-Vercel-IP-Country-Region", "X-Geo-Region-Code")),
		Country:     headerLocationValue(firstHeader(r, "CF-IPCountryName", "X-Vercel-IP-Country-Name", "X-Geo-Country-Name")),
		CountryCode: strings.ToUpper(headerLocationValue(countryCode)),
		Source:      "headers",
		UpdatedAt:   time.Now().UTC(),
	}
	loc.Latitude = parseHeaderFloat(firstHeader(r, "CF-IPLatitude", "X-Vercel-IP-Latitude", "X-Geo-Latitude"))
	loc.Longitude = parseHeaderFloat(firstHeader(r, "CF-IPLongitude", "X-Vercel-IP-Longitude", "X-Geo-Longitude"))
	if loc.Country == "" {
		loc.Country = loc.CountryCode
	}
	return loc
}

func firstHeader(r *http.Request, names ...string) string {
	for _, name := range names {
		if v := strings.TrimSpace(r.Header.Get(name)); v != "" {
			return v
		}
	}
	return ""
}

func headerLocationValue(v string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return ""
	}
	if decoded, err := url.QueryUnescape(v); err == nil {
		v = decoded
	}
	return strings.TrimSpace(v)
}

func parseHeaderFloat(v string) float64 {
	f, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
	if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
		return 0
	}
	return f
}
