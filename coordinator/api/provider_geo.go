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
)

type providerGeoResolver interface {
	Lookup(*http.Request) *store.ProviderLocation
}

type ipAPIGeoResolver struct {
	trustHeaders bool
	logger       *slog.Logger
}

func newProviderGeoResolverFromEnv(logger *slog.Logger) providerGeoResolver {
	trustHeaders := os.Getenv(envTrustGeoHeaders) == "1"
	return &ipAPIGeoResolver{
		trustHeaders: trustHeaders,
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

// lookupIPAPI resolves geolocation via the free ip-api.com service.
// No API key required. Rate limit: 45 req/min — called once per provider
// WebSocket connection, so even 250 concurrent providers is fine.
func (g *ipAPIGeoResolver) lookupIPAPI(ip net.IP) *store.ProviderLocation {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	apiURL := fmt.Sprintf("http://ip-api.com/json/%s?fields=status,country,countryCode,regionName,region,city,lat,lon,timezone", ip.String())
	req, err := http.NewRequestWithContext(ctx, "GET", apiURL, nil)
	if err != nil {
		return nil
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		if g.logger != nil {
			g.logger.Debug("ip-api lookup failed", "ip", ip.String(), "error", err)
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
			g.logger.Debug("ip-api lookup unsuccessful", "ip", ip.String(), "status", result.Status)
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
		Source:      "ip-api",
		UpdatedAt:   time.Now().UTC(),
	}
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
