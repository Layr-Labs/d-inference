package api

import (
	"net/http"
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
