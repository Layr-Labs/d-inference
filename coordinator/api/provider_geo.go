package api

import (
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
	"github.com/oschwald/geoip2-golang"
)

const (
	envGeoIPDBPath     = "EIGENINFERENCE_GEOIP_DB"
	envTrustGeoHeaders = "EIGENINFERENCE_TRUST_GEO_HEADERS"
)

type providerGeoResolver interface {
	Lookup(*http.Request) *store.ProviderLocation
}

type maxMindGeoResolver struct {
	reader       *geoip2.Reader
	trustHeaders bool
	logger       *slog.Logger
}

func newProviderGeoResolverFromEnv(logger *slog.Logger) providerGeoResolver {
	path := strings.TrimSpace(os.Getenv(envGeoIPDBPath))
	trustHeaders := os.Getenv(envTrustGeoHeaders) == "1"
	if path == "" && !trustHeaders {
		return nil
	}

	var reader *geoip2.Reader
	if path != "" {
		r, err := geoip2.Open(path)
		if err != nil {
			if logger != nil {
				logger.Warn("provider geo database unavailable", "path", path, "error", err)
			}
		} else {
			reader = r
		}
	}

	if reader == nil && !trustHeaders {
		return nil
	}
	return &maxMindGeoResolver{
		reader:       reader,
		trustHeaders: trustHeaders,
		logger:       logger,
	}
}

func (g *maxMindGeoResolver) Lookup(r *http.Request) *store.ProviderLocation {
	if g == nil || r == nil {
		return nil
	}
	if g.trustHeaders {
		remoteIP := parseIPHost(r.RemoteAddr)
		if remoteIP != nil && trustedProxyIP(remoteIP) {
			if loc := locationFromTrustedGeoHeaders(r); loc != nil {
				return loc
			}
		}
	}
	if g.reader == nil {
		return nil
	}
	ip := providerClientIP(r)
	if ip == nil || !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() {
		return nil
	}
	record, err := g.reader.City(ip)
	if err != nil {
		if g.logger != nil {
			g.logger.Debug("provider geo lookup failed", "error", err)
		}
		return nil
	}
	if record == nil || record.Country.IsoCode == "" {
		return nil
	}

	loc := &store.ProviderLocation{
		City:             englishName(record.City.Names),
		Country:          englishName(record.Country.Names),
		CountryCode:      strings.ToUpper(record.Country.IsoCode),
		Latitude:         record.Location.Latitude,
		Longitude:        record.Location.Longitude,
		AccuracyRadiusKM: int(record.Location.AccuracyRadius),
		Timezone:         record.Location.TimeZone,
		Source:           "maxmind",
		UpdatedAt:        time.Now().UTC(),
	}
	if len(record.Subdivisions) > 0 {
		sub := record.Subdivisions[0]
		loc.Region = englishName(sub.Names)
		loc.RegionCode = sub.IsoCode
	}
	if loc.Country == "" {
		loc.Country = loc.CountryCode
	}
	return loc
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

func englishName(names map[string]string) string {
	if names == nil {
		return ""
	}
	if v := strings.TrimSpace(names["en"]); v != "" {
		return v
	}
	for _, v := range names {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}
