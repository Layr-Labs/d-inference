package mediafetch

import (
	"errors"
	"net/netip"
	"net/url"
	"testing"
)

func TestIPAllowed(t *testing.T) {
	cases := []struct {
		ip           string
		allowPrivate bool
		want         bool
	}{
		// Public addresses are allowed under the strict policy.
		{"8.8.8.8", false, true},
		{"1.1.1.1", false, true},
		{"93.184.216.34", false, true}, // example.com
		{"2606:4700:4700::1111", false, true},
		{"::ffff:8.8.8.8", false, true}, // IPv4-mapped public

		// Loopback / private / link-local / metadata / unspecified are blocked.
		{"127.0.0.1", false, false},
		{"127.10.20.30", false, false},
		{"10.0.0.1", false, false},
		{"172.16.5.4", false, false},
		{"192.168.1.1", false, false},
		{"169.254.169.254", false, false}, // cloud metadata
		{"169.254.1.1", false, false},     // link-local
		{"0.0.0.0", false, false},
		{"::1", false, false},
		{"fc00::1", false, false},                // IPv6 ULA
		{"fe80::1", false, false},                // IPv6 link-local
		{"::ffff:127.0.0.1", false, false},       // IPv4-mapped loopback (bypass attempt)
		{"::ffff:192.168.1.1", false, false},     // IPv4-mapped private
		{"::ffff:169.254.169.254", false, false}, // IPv4-mapped metadata
		{"224.0.0.1", false, false},              // multicast
		{"::", false, false},                     // unspecified IPv6

		// Ranges the stdlib helpers report as global-unicast but must still be
		// blocked (these slip past IsPrivate/IsGlobalUnicast).
		{"64:ff9b::7f00:1", false, false},                         // NAT64 of 127.0.0.1 (loopback bypass)
		{"64:ff9b::a00:1", false, false},                          // NAT64 of 10.0.0.1
		{"64:ff9b:1::1", false, false},                            // NAT64 local-use prefix
		{"::7f00:1", false, false},                                // IPv4-compatible 127.0.0.1
		{"::a00:1", false, false},                                 // IPv4-compatible 10.0.0.1
		{"2002:7f00:1::1", false, false},                          // 6to4 embedding 127.0.0.1
		{"2002:a9fe:a9fe::1", false, false},                       // 6to4 embedding metadata 169.254.169.254
		{"2001:0000:4136:e378:8000:63bf:3fff:fdd2", false, false}, // Teredo
		{"100.64.0.1", false, false},                              // CGNAT / RFC 6598
		{"100.127.255.1", false, false},                           // CGNAT upper bound
		{"198.18.0.1", false, false},                              // benchmarking
		{"192.0.2.5", false, false},                               // TEST-NET-1
		{"240.0.0.1", false, false},                               // reserved
		{"255.255.255.255", false, false},                         // broadcast (in 240/4)
		{"2001:db8::1", false, false},                             // IPv6 documentation
		{"192.88.99.1", false, false},                             // deprecated 6to4 relay anycast
		{"fec0::1", false, false},                                 // deprecated IPv6 site-local
		{"0.0.0.1", false, false},                                 // 0.0.0.0/8 "this network" (IsUnspecified only matches 0.0.0.0)
		{"0.255.255.255", false, false},                           // 0.0.0.0/8 upper bound

		// IPv4-mapped forms whose ONLY deny path is blockedPrefixes: netip's
		// IsLoopback/IsPrivate/IsLinkLocalUnicast are themselves 4-in-6 aware, so
		// the ::ffff:127.0.0.1-style cases above stay blocked even without the
		// Unmap. These ranges have no such helper — Prefix.Contains compares the
		// 16-byte form and never matches an IPv4 prefix — so each of these fails
		// if `if ip.Is4In6() { ip = ip.Unmap() }` is removed from ipAllowed.
		{"::ffff:100.64.0.1", false, false}, // IPv4-mapped CGNAT
		{"::ffff:198.18.0.1", false, false}, // IPv4-mapped benchmarking
		{"::ffff:240.0.0.1", false, false},  // IPv4-mapped reserved
		{"::ffff:192.0.2.5", false, false},  // IPv4-mapped TEST-NET-1

		// Zoned IPv6: netip.Prefix.Contains returns false for ANY address that
		// carries a zone, so a "%zone" suffix skips the whole blockedPrefixes
		// loop unless ipAllowed strips it first. The zone survives url.Parse →
		// u.Hostname() → canonicalAddr → the dialer Control hook, and an unknown
		// zone name resolves to ZoneId 0 so the kernel dials the bare address.
		// Each of these fails if `ip = ip.WithZone("")` is removed.
		{"64:ff9b::a9fe:a9fe%eth0", false, false}, // NAT64 of metadata 169.254.169.254
		{"64:ff9b::7f00:1%eth0", false, false},    // NAT64 of loopback
		{"2002:7f00:1::1%z", false, false},        // 6to4 embedding 127.0.0.1
		{"::7f00:1%z", false, false},              // IPv4-compatible 127.0.0.1
		{"2001::1%z", false, false},               // Teredo
		{"fec0::1%z", false, false},               // deprecated IPv6 site-local

		// allowPrivate (dev/test) permits private/loopback but still blocks the
		// unspecified address.
		{"127.0.0.1", true, true},
		{"192.168.1.1", true, true},
		{"0.0.0.0", true, false},
	}
	for _, c := range cases {
		ip := netip.MustParseAddr(c.ip)
		if got := ipAllowed(ip, c.allowPrivate); got != c.want {
			t.Errorf("ipAllowed(%s, allowPrivate=%v) = %v, want %v", c.ip, c.allowPrivate, got, c.want)
		}
	}
}

func TestValidateURL(t *testing.T) {
	cfg := DefaultConfig()
	cfg.BlocklistDomains = map[string]bool{"evil.com": true}
	cases := []struct {
		raw     string
		wantErr error // nil = allowed
	}{
		{"https://example.com/cat.jpg", nil},
		{"http://example.com", nil},
		{"HTTPS://Example.com/x", nil},
		{"http://example.com:80/x", nil},
		{"https://example.com:443/x", nil},
		{"http://example.com:8080/x", errBlockedHost},
		{"https://example.com:8443/x", errBlockedHost},
		{"ftp://example.com/x", errBlockedScheme},
		{"file:///etc/passwd", errBlockedScheme},
		{"gopher://example.com", errBlockedScheme},
		{"https://user:pass@example.com/x", errBlockedHost}, // embedded credentials
		{"https://evil.com/x", errBlockedHost},              // blocklisted domain
		{"https://EVIL.com/x", errBlockedHost},              // blocklist is case-insensitive
		{"https://evil.com:8443/x", errBlockedHost},         // blocklist ignores port
		{"https://images.evil.com/x", errBlockedHost},       // subdomain inherits parent block
		{"https://not-evil.com/x", nil},                     // suffix without label boundary is unrelated

		// UTS-46 maps these separators to an ASCII dot, and net/http's
		// canonicalAddr runs the host through idna.Lookup.ToASCII before it
		// dials. Matching the raw host would read each of these as ONE label
		// (no blocklist hit) while the socket lands on evil.com. Each fails if
		// the idna.Lookup.ToASCII normalization is removed from canonicalHost.
		{"https://evil\u3002com/x", errBlockedHost},          // U+3002 IDEOGRAPHIC FULL STOP
		{"https://img\uff0eevil\uff0ecom/x", errBlockedHost}, // U+FF0E FULLWIDTH FULL STOP
		{"https://evil\uff61com/x", errBlockedHost},          // U+FF61 HALFWIDTH IDEOGRAPHIC FULL STOP
		{"https://notevil\u3002com/x", nil},                  // canonicalizes to notevil.com — must NOT over-block
	}
	for _, c := range cases {
		u, err := url.Parse(c.raw)
		if err != nil {
			t.Fatalf("url.Parse(%q): %v", c.raw, err)
		}
		got := validateURL(u, cfg)
		switch {
		case c.wantErr == nil && got != nil:
			t.Errorf("validateURL(%q) = %v, want nil", c.raw, got)
		case c.wantErr != nil && !errors.Is(got, c.wantErr):
			t.Errorf("validateURL(%q) = %v, want errors.Is %v", c.raw, got, c.wantErr)
		}
	}

	cfg.AllowNonStandardPorts = true
	u, err := url.Parse("http://example.com:8080/x")
	if err != nil {
		t.Fatal(err)
	}
	if err := validateURL(u, cfg); err != nil {
		t.Errorf("AllowNonStandardPorts=true must allow controlled dev/test origins: %v", err)
	}
}

// TestHostAllowedIDNACanonicalization pins the blocklist comparison to the
// namespace the transport actually dials in. Removing the idna.Lookup.ToASCII
// call from canonicalHost flips every "blocked: true" Unicode row to allowed.
func TestHostAllowedIDNACanonicalization(t *testing.T) {
	blocklist := parseBlocklist("evil.com")
	cases := []struct {
		host    string
		blocked bool
	}{
		{"evil.com", true},               // plain-ASCII control
		{"EVIL.COM", true},               // ASCII case folding
		{"img.evil.com", true},           // ASCII subdomain
		{"evil.com.", true},              // FQDN trailing dot
		{"example.com", false},           // plain-ASCII control, unrelated host
		{"notevil.com", false},           // ASCII near-miss stays allowed
		{"evil\u3002com", true},          // U+3002 IDEOGRAPHIC FULL STOP
		{"EVIL\u3002com", true},          // mixed case + U+3002
		{"evil\uff0ecom", true},          // U+FF0E FULLWIDTH FULL STOP
		{"evil\uff61com", true},          // U+FF61 HALFWIDTH IDEOGRAPHIC FULL STOP
		{"img\u3002evil\u3002com", true}, // subdomain via mapped separators
		{"evil\u3002com:443", true},      // host:port form
		{"notevil\u3002com", false},      // maps to notevil.com — must NOT over-block
	}
	for _, c := range cases {
		err := hostAllowed(c.host, blocklist)
		if got := err != nil; got != c.blocked {
			t.Errorf("hostAllowed(%q) blocked = %v, want %v (err=%v)", c.host, got, c.blocked, err)
		}
		if err != nil && !errors.Is(err, errBlockedHost) {
			t.Errorf("hostAllowed(%q) = %v, want errors.Is errBlockedHost", c.host, err)
		}
	}
}

func TestIsRemoteMediaURL(t *testing.T) {
	cases := map[string]bool{
		"http://example.com/a.png":           true,
		"https://example.com/a.png":          true,
		"  https://example.com/a.png  ":      true,
		"HTTPS://example.com":                true,
		"data:image/png;base64,iVBORw0KGgo=": false,
		"file:///etc/passwd":                 false,
		"ftp://example.com/x":                false,
		"":                                   false,
		"https:/":                            false,
	}
	for in, want := range cases {
		if got := isRemoteMediaURL(in); got != want {
			t.Errorf("isRemoteMediaURL(%q) = %v, want %v", in, got, want)
		}
	}
}

// Sniffing/allowlist/pixel-cap tests live in sniff_test.go.
