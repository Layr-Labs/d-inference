package api

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
)

func TestProviderClientIPUsesForwardedForOnlyBehindTrustedProxy(t *testing.T) {
	req, err := http.NewRequest(http.MethodGet, "/v1/providers/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.RemoteAddr = "127.0.0.1:49321"
	req.Header.Set("X-Forwarded-For", "198.51.100.22, 203.0.113.10")

	ip := providerClientIP(req)
	if got, want := ip.String(), "203.0.113.10"; got != want {
		t.Fatalf("providerClientIP = %s, want %s", got, want)
	}

	req.RemoteAddr = "203.0.113.44:49321"
	if got := providerClientIP(req).String(); got != "203.0.113.44" {
		t.Fatalf("providerClientIP with untrusted remote = %s, want remote addr", got)
	}
}

func TestLocationFromTrustedGeoHeaders(t *testing.T) {
	req, err := http.NewRequest(http.MethodGet, "/v1/providers/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("X-Vercel-IP-City", "San%20Francisco")
	req.Header.Set("X-Vercel-IP-Country-Region", "CA")
	req.Header.Set("X-Vercel-IP-Country", "US")
	req.Header.Set("X-Vercel-IP-Latitude", "37.7749")
	req.Header.Set("X-Vercel-IP-Longitude", "-122.4194")

	loc := locationFromTrustedGeoHeaders(req)
	if loc == nil {
		t.Fatal("expected location")
	}
	if loc.City != "San Francisco" || loc.Region != "CA" || loc.CountryCode != "US" {
		t.Fatalf("unexpected location: %#v", loc)
	}
	if loc.Latitude != 37.7749 || loc.Longitude != -122.4194 {
		t.Fatalf("unexpected coordinates: %#v", loc)
	}
}

// ipAPIResolverFromEnv constructs the concrete resolver and asserts the env
// wiring produced an *ipAPIGeoResolver (the only implementation).
func ipAPIResolverFromEnv(t *testing.T) *ipAPIGeoResolver {
	t.Helper()
	r, ok := newProviderGeoResolverFromEnv(nil).(*ipAPIGeoResolver)
	if !ok {
		t.Fatalf("newProviderGeoResolverFromEnv returned %T, want *ipAPIGeoResolver", r)
	}
	return r
}

func TestNewProviderGeoResolverUsesProEndpointWithKey(t *testing.T) {
	t.Setenv(envIPAPIKey, "fake-pro-key")

	g := ipAPIResolverFromEnv(t)
	if g.apiKey != "fake-pro-key" {
		t.Fatalf("apiKey = %q, want fake-pro-key", g.apiKey)
	}
	if g.baseURL != ipAPIProBaseURL {
		t.Fatalf("baseURL = %q, want %q", g.baseURL, ipAPIProBaseURL)
	}
	if got := g.sourceLabel(); got != "ip-api-pro" {
		t.Fatalf("sourceLabel = %q, want ip-api-pro", got)
	}
}

func TestNewProviderGeoResolverFreeEndpointWithoutKey(t *testing.T) {
	// Empty value behaves exactly like unset (graceful free-tier fallback).
	t.Setenv(envIPAPIKey, "  ")

	g := ipAPIResolverFromEnv(t)
	if g.apiKey != "" {
		t.Fatalf("apiKey = %q, want empty", g.apiKey)
	}
	if g.baseURL != ipAPIFreeBaseURL {
		t.Fatalf("baseURL = %q, want %q", g.baseURL, ipAPIFreeBaseURL)
	}
	if got := g.sourceLabel(); got != "ip-api" {
		t.Fatalf("sourceLabel = %q, want ip-api", got)
	}
}

func TestBuildLookupURL(t *testing.T) {
	ip := net.ParseIP("8.8.8.8")
	const fields = "fields=status,country,countryCode,regionName,region,city,lat,lon,timezone"

	tests := []struct {
		name   string
		apiKey string
		base   string
		want   string
	}{
		{
			name: "free tier omits key",
			base: ipAPIFreeBaseURL,
			want: "http://ip-api.com/json/8.8.8.8?" + fields,
		},
		{
			name:   "pro tier appends key over https",
			apiKey: "fake-pro-key",
			base:   ipAPIProBaseURL,
			want:   "https://pro.ip-api.com/json/8.8.8.8?" + fields + "&key=fake-pro-key",
		},
		{
			name:   "key with reserved chars is escaped",
			apiKey: "a b&c",
			base:   ipAPIProBaseURL,
			want:   "https://pro.ip-api.com/json/8.8.8.8?" + fields + "&key=a+b%26c",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			g := &ipAPIGeoResolver{apiKey: tc.apiKey, baseURL: tc.base}
			if got := g.buildLookupURL(ip); got != tc.want {
				t.Fatalf("buildLookupURL = %q, want %q", got, tc.want)
			}
		})
	}
}

const ipAPISuccessBody = `{"status":"success","country":"United States","countryCode":"US",` +
	`"regionName":"California","region":"CA","city":"Mountain View",` +
	`"lat":37.4056,"lon":-122.0775,"timezone":"America/Los_Angeles"}`

func TestLookupIPAPIProUsesKeyAndParsesResponse(t *testing.T) {
	var gotURL *url.URL
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotURL = r.URL
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, ipAPISuccessBody)
	}))
	defer ts.Close()

	g := &ipAPIGeoResolver{apiKey: "fake-pro-key", baseURL: ts.URL, httpClient: ts.Client()}
	loc := g.lookupIPAPI(net.ParseIP("8.8.8.8"))

	if gotURL == nil {
		t.Fatal("server received no request")
	}
	if gotURL.Path != "/json/8.8.8.8" {
		t.Fatalf("request path = %q, want /json/8.8.8.8", gotURL.Path)
	}
	if got := gotURL.Query().Get("key"); got != "fake-pro-key" {
		t.Fatalf("key query = %q, want fake-pro-key", got)
	}
	if got := gotURL.Query().Get("fields"); got != ipAPIFields {
		t.Fatalf("fields query = %q, want %q", got, ipAPIFields)
	}

	if loc == nil {
		t.Fatal("expected location")
	}
	if loc.City != "Mountain View" || loc.Region != "California" || loc.RegionCode != "CA" {
		t.Fatalf("unexpected location: %#v", loc)
	}
	if loc.Country != "United States" || loc.CountryCode != "US" {
		t.Fatalf("unexpected country: %#v", loc)
	}
	if loc.Latitude != 37.4056 || loc.Longitude != -122.0775 {
		t.Fatalf("unexpected coordinates: %#v", loc)
	}
	if loc.Timezone != "America/Los_Angeles" {
		t.Fatalf("unexpected timezone: %q", loc.Timezone)
	}
	if loc.Source != "ip-api-pro" {
		t.Fatalf("Source = %q, want ip-api-pro", loc.Source)
	}
}

func TestLookupIPAPIFreeOmitsKey(t *testing.T) {
	var gotURL *url.URL
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotURL = r.URL
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, ipAPISuccessBody)
	}))
	defer ts.Close()

	g := &ipAPIGeoResolver{apiKey: "", baseURL: ts.URL, httpClient: ts.Client()}
	loc := g.lookupIPAPI(net.ParseIP("8.8.8.8"))

	if gotURL == nil {
		t.Fatal("server received no request")
	}
	if gotURL.Query().Has("key") {
		t.Fatalf("free tier must not send a key, got query %q", gotURL.RawQuery)
	}
	if loc == nil || loc.Source != "ip-api" {
		t.Fatalf("Source = %v, want ip-api", loc)
	}
}
