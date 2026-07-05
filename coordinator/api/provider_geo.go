package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	envTrustGeoHeaders = "EIGENINFERENCE_TRUST_GEO_HEADERS"
	// envIPAPIKey holds the ip-api.com PRO API key. It is a SECRET — injected via
	// the deployment env (EigenCloud KMS / GCP Secret Manager), never committed.
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
)

type providerGeoResolver interface {
	Lookup(*http.Request) *store.ProviderLocation
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
	// httpClient performs the lookup. Defaults to http.DefaultClient; overridable
	// in tests. A nil client falls back to http.DefaultClient at call time.
	httpClient *http.Client
	logger     *slog.Logger
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
		httpClient:   http.DefaultClient,
		logger:       logger,
	}
}

func (g *ipAPIGeoResolver) Lookup(r *http.Request) *store.ProviderLocation {
	if g == nil || r == nil {
		return nil
	}
	// If behind a trusted proxy that sets geo headers (Cloudflare, Vercel),
	// use those directly — no external API call needed.
	if g.trustHeaders {
		remoteIP := parseIPHost(r.RemoteAddr)
		if remoteIP != nil && trustedProxyIP(remoteIP) {
			if loc := locationFromTrustedGeoHeaders(r); loc != nil {
				return loc
			}
		}
	}

	// Extract the provider's real public IP and look it up via ip-api.com.
	ip := providerClientIP(r)
	if ip == nil || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() {
		return nil
	}
	return g.lookupIPAPI(ip)
}

// lookupIPAPI resolves geolocation via ip-api.com.
//
// With a PRO key (EIGENINFERENCE_IPAPI_KEY) it uses the unmetered
// https://pro.ip-api.com endpoint; without one it falls back to the free
// http://ip-api.com endpoint (45 req/min by source IP — called once per provider
// WebSocket connection, so even 250 concurrent providers is fine on the free
// tier). The Source field records which tier answered ("ip-api-pro" vs "ip-api").
func (g *ipAPIGeoResolver) lookupIPAPI(ip net.IP) *store.ProviderLocation {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
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
			g.logger.Debug("ip-api lookup failed", "ip", ip.String(), "pro", g.apiKey != "", "error", err)
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

func (s *Server) requestLocation(r *http.Request) *store.ProviderLocation {
	if s == nil || s.geoResolver == nil || r == nil {
		return nil
	}
	loc := s.geoResolver.Lookup(r)
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
