package geo_test

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/geo"
)

func TestProviderClientIPUsesForwardedForOnlyBehindTrustedProxy(t *testing.T) {
	req, err := http.NewRequest(http.MethodGet, "/v1/providers/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.RemoteAddr = "127.0.0.1:49321"
	req.Header.Set("X-Forwarded-For", "198.51.100.22, 203.0.113.10")

	var requested string
	g := production.NewResolver(production.Config{HTTPClient: &http.Client{Transport: captureTransport(func(r *http.Request) { requested = strings.TrimPrefix(r.URL.Path, "/json/") })}})
	g.Lookup(req)
	if got, want := requested, "203.0.113.10"; got != want {
		t.Fatalf("providerClientIP = %s, want %s", got, want)
	}

	req.RemoteAddr = "203.0.113.44:49321"
	g.Lookup(req)
	if got := requested; got != "203.0.113.44" {
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

	req.RemoteAddr = "127.0.0.1:1234"
	loc := production.NewResolver(production.Config{TrustHeaders: true}).Lookup(req)
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

type captureTransport func(*http.Request)

func (f captureTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	f(r)
	return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(ipAPISuccessBody)), Request: r}, nil
}

func lookupRequest() *http.Request {
	r := httptest.NewRequest(http.MethodGet, "/v1/providers/ws", nil)
	r.RemoteAddr = "8.8.8.8:1234"
	return r
}

func TestNewProviderGeoResolverUsesProEndpointWithKey(t *testing.T) {
	t.Setenv("EIGENINFERENCE_IPAPI_KEY", "fake-pro-key")
	previous := http.DefaultClient
	t.Cleanup(func() { http.DefaultClient = previous })
	http.DefaultClient = &http.Client{Transport: captureTransport(func(r *http.Request) {
		if r.URL.Query().Get("key") != "fake-pro-key" {
			t.Errorf("apiKey = %q, want fake-pro-key", r.URL.Query().Get("key"))
		}
		if r.URL.Scheme+"://"+r.URL.Host != "https://pro.ip-api.com" {
			t.Errorf("unexpected PRO endpoint: %s", r.URL)
		}
	})}
	g := production.NewResolverFromEnv(nil)
	if got := g.Lookup(lookupRequest()).Source; got != "ip-api-pro" {
		t.Fatalf("sourceLabel = %q, want ip-api-pro", got)
	}
}

func TestNewProviderGeoResolverFreeEndpointWithoutKey(t *testing.T) {
	// Empty value behaves exactly like unset (graceful free-tier fallback).
	t.Setenv("EIGENINFERENCE_IPAPI_KEY", "  ")
	previous := http.DefaultClient
	t.Cleanup(func() { http.DefaultClient = previous })
	http.DefaultClient = &http.Client{Transport: captureTransport(func(r *http.Request) {
		if r.URL.Query().Has("key") {
			t.Errorf("apiKey = %q, want empty", r.URL.Query().Get("key"))
		}
		if r.URL.Scheme+"://"+r.URL.Host != "http://ip-api.com" {
			t.Errorf("unexpected free endpoint: %s", r.URL)
		}
	})}
	g := production.NewResolverFromEnv(nil)
	if got := g.Lookup(lookupRequest()).Source; got != "ip-api" {
		t.Fatalf("sourceLabel = %q, want ip-api", got)
	}
}

func TestBuildLookupURL(t *testing.T) {
	const fields = "fields=status,country,countryCode,regionName,region,city,lat,lon,timezone"

	tests := []struct {
		name   string
		apiKey string
		base   string
		want   string
	}{
		{
			name: "free tier omits key",
			base: "http://ip-api.com",
			want: "http://ip-api.com/json/8.8.8.8?" + fields,
		},
		{
			name:   "pro tier appends key over https",
			apiKey: "fake-pro-key",
			base:   "https://pro.ip-api.com",
			want:   "https://pro.ip-api.com/json/8.8.8.8?" + fields + "&key=fake-pro-key",
		},
		{
			name:   "key with reserved chars is escaped",
			apiKey: "a b&c",
			base:   "https://pro.ip-api.com",
			want:   "https://pro.ip-api.com/json/8.8.8.8?" + fields + "&key=a+b%26c",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			g := production.NewResolver(production.Config{APIKey: tc.apiKey, BaseURL: tc.base, HTTPClient: &http.Client{Transport: captureTransport(func(r *http.Request) {
				if got := r.URL.String(); got != tc.want {
					t.Errorf("buildLookupURL = %q, want %q", got, tc.want)
				}
			})}})
			g.Lookup(lookupRequest())
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

	g := production.NewResolver(production.Config{APIKey: "fake-pro-key", BaseURL: ts.URL, HTTPClient: ts.Client()})
	loc := g.Lookup(lookupRequest())

	if gotURL == nil {
		t.Fatal("server received no request")
	}
	if gotURL.Path != "/json/8.8.8.8" {
		t.Fatalf("request path = %q, want /json/8.8.8.8", gotURL.Path)
	}
	if got := gotURL.Query().Get("key"); got != "fake-pro-key" {
		t.Fatalf("key query = %q, want fake-pro-key", got)
	}
	const fields = "status,country,countryCode,regionName,region,city,lat,lon,timezone"
	if got := gotURL.Query().Get("fields"); got != fields {
		t.Fatalf("fields query = %q, want %q", got, fields)
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

	g := production.NewResolver(production.Config{BaseURL: ts.URL, HTTPClient: ts.Client()})
	loc := g.Lookup(lookupRequest())

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
