package mediafetch

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"syscall"

	"golang.org/x/net/idna"
)

// errBlockedIP is returned (wrapped) by the dialer Control hook when a socket is
// about to connect to a denied address. Callers detect it with errors.Is to map
// the failure to a 403 instead of a generic network error.
var errBlockedIP = errors.New("mediafetch: destination IP is not allowed")

// errBlockedScheme / errBlockedHost surface non-IP rejections (scheme, userinfo,
// blocklisted domain) with the same errors.Is treatment.
var (
	errBlockedScheme = errors.New("mediafetch: URL scheme is not allowed")
	errBlockedHost   = errors.New("mediafetch: host is not allowed")
)

// blockedMetadataV4 is the cloud metadata service address (AWS/GCP/Azure all use
// 169.254.169.254). It is already covered by the link-local 169.254.0.0/16 deny
// below, but we keep it explicit for clarity and defense against future changes.
var blockedMetadataV4 = netip.MustParseAddr("169.254.169.254")

// blockedPrefixes are ranges that net/netip's IsPrivate/IsLoopback/IsLinkLocal/
// IsGlobalUnicast helpers do NOT classify as non-global — so without this
// explicit list they would be (wrongly) allowed. The critical ones are IPv6
// transition mechanisms that embed or tunnel IPv4 destinations — NAT64, 6to4,
// Teredo, and the deprecated 6to4 relay anycast — because an embedded loopback,
// metadata, or RFC1918 address can bypass an IPv4-only deny policy if the host
// has the corresponding tunnel configured. CGNAT/RFC6598 is also denied because
// it commonly reaches internal cloud/VPC overlays. The rest are benchmarking,
// documentation, IETF-assignment, deprecated site-local, and reserved ranges
// that are never a legitimate public media origin. Transition space is denied
// outright; coordinator hosts are dual-stack and never need it — fail closed.
var blockedPrefixes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),       // "this network" (RFC 1122); IsUnspecified only matches 0.0.0.0 exactly
	netip.MustParsePrefix("100.64.0.0/10"),   // CGNAT / RFC 6598 shared address space
	netip.MustParsePrefix("192.0.0.0/24"),    // IETF protocol assignments (RFC 6890)
	netip.MustParsePrefix("192.88.99.0/24"),  // deprecated 6to4 relay anycast (RFC 7526)
	netip.MustParsePrefix("192.0.2.0/24"),    // TEST-NET-1 (documentation)
	netip.MustParsePrefix("198.18.0.0/15"),   // benchmarking (RFC 2544)
	netip.MustParsePrefix("198.51.100.0/24"), // TEST-NET-2 (documentation)
	netip.MustParsePrefix("203.0.113.0/24"),  // TEST-NET-3 (documentation)
	netip.MustParsePrefix("240.0.0.0/4"),     // reserved / future use (incl. 255.255.255.255)
	netip.MustParsePrefix("64:ff9b::/96"),    // NAT64 well-known prefix (RFC 6052)
	netip.MustParsePrefix("64:ff9b:1::/48"),  // NAT64 local-use prefix (RFC 8215)
	netip.MustParsePrefix("::/96"),           // deprecated IPv4-compatible IPv6 (e.g. ::127.0.0.1)
	netip.MustParsePrefix("2001::/32"),       // Teredo (RFC 4380; embeds IPv4 endpoints)
	netip.MustParsePrefix("2002::/16"),       // 6to4 (RFC 3056; embeds an IPv4 destination)
	netip.MustParsePrefix("2001:db8::/32"),   // IPv6 documentation (RFC 3849)
	netip.MustParsePrefix("100::/64"),        // IPv6 discard-only (RFC 6666)
	netip.MustParsePrefix("fec0::/10"),       // deprecated IPv6 site-local space (RFC 3879)
}

// ipAllowed reports whether dialing ip is permitted under the SSRF policy.
// allowPrivate=true (dev/test) bypasses the deny set so httptest's 127.0.0.1
// servers are reachable.
//
// Denied (when allowPrivate is false): loopback (127.0.0.0/8, ::1), RFC1918
// private (10/8, 172.16/12, 192.168/16), IPv6 ULA (fc00::/7), link-local
// (169.254/16, fe80::/10) including cloud metadata, unspecified (0.0.0.0, ::),
// multicast, and anything not classified as a normal global-unicast address.
// IPv4-mapped IPv6 (::ffff:a.b.c.d) is unmapped first so the inner IPv4 is judged
// by the IPv4 rules — closing a classic blocklist bypass — and any IPv6 zone
// ("%eth0") is stripped so a zoned address cannot skip the prefix deny set.
func ipAllowed(ip netip.Addr, allowPrivate bool) bool {
	if !ip.IsValid() {
		return false
	}
	// Normalize IPv4-mapped IPv6 (::ffff:127.0.0.1) to its IPv4 form so the
	// loopback/private checks below see the real address.
	if ip.Is4In6() {
		ip = ip.Unmap()
	}
	// Strip any IPv6 zone ("fe80::1%eth0"). netip.Prefix.Contains returns false
	// for EVERY zoned address, so without this the whole blockedPrefixes loop is
	// silently skipped — a zone suffix survives url.Parse → u.Hostname() →
	// http.Transport's canonicalAddr → this Control hook, and an unknown zone
	// name resolves to ZoneId 0 so the kernel still dials the bare address.
	// Zones are meaningless for an outbound media fetch; drop before any policy
	// evaluation so BOTH the dial-time hook and direct callers are covered.
	ip = ip.WithZone("")
	if allowPrivate {
		// Dev/test: only reject the obviously-bogus unspecified address.
		return !ip.IsUnspecified()
	}
	// Explicit deny of ranges the stdlib helpers misclassify as global-unicast
	// (NAT64, CGNAT, benchmarking, documentation, reserved). Checked before the
	// helper-based switch below.
	for _, p := range blockedPrefixes {
		if p.Contains(ip) {
			return false
		}
	}
	switch {
	case ip.IsLoopback(): // 127.0.0.0/8, ::1
		return false
	case ip.IsPrivate(): // 10/8, 172.16/12, 192.168/16, fc00::/7
		return false
	case ip.IsLinkLocalUnicast(): // 169.254/16, fe80::/10 (covers cloud metadata)
		return false
	case ip.IsLinkLocalMulticast() || ip.IsMulticast():
		return false
	case ip.IsUnspecified(): // 0.0.0.0, ::
		return false
	case ip.IsInterfaceLocalMulticast():
		return false
	case ip == blockedMetadataV4:
		return false
	case !ip.IsGlobalUnicast():
		// Reject anything not a routable global-unicast address (reserved,
		// benchmarking, documentation ranges, etc.) — fail closed.
		return false
	default:
		return true
	}
}

// dialControl returns a net.Dialer.Control hook that validates the actual
// resolved IP the socket is about to connect to — after DNS resolution, before
// the connect syscall. This is the rebinding/TOCTOU-proof core of the SSRF
// defense: a hostname that resolves "public" at validation time but "private" at
// connect time is still caught, because every dial (including each redirect hop's
// dial) runs through here against the literal connect address Go hands us.
func dialControl(allowPrivate bool) func(network, address string, c syscall.RawConn) error {
	return func(network, address string, _ syscall.RawConn) error {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			// Control is called with a resolved host:port; a parse failure is
			// unexpected — fail closed.
			return fmt.Errorf("%w: unparseable dial address %q", errBlockedIP, address)
		}
		ip, err := netip.ParseAddr(host)
		if err != nil {
			// Go resolves the hostname to an IP literal before calling Control,
			// so a non-IP host here is anomalous — fail closed.
			return fmt.Errorf("%w: non-IP dial host %q", errBlockedIP, host)
		}
		if !ipAllowed(ip, allowPrivate) {
			return fmt.Errorf("%w: %s", errBlockedIP, ip)
		}
		return nil
	}
}

// canonicalHost normalizes a hostname so both sides of a blocklist comparison
// see the same string the transport will actually dial.
//
// net/http runs a non-ASCII host through idna.Lookup.ToASCII (UTS-46) in
// canonicalAddr before dialing, and UTS-46 maps U+3002 IDEOGRAPHIC FULL STOP,
// U+FF0E FULLWIDTH FULL STOP and U+FF61 HALFWIDTH IDEOGRAPHIC FULL STOP to an
// ASCII dot. Comparing the raw host would therefore read "evil\u3002com" as one
// label (no blocklist hit) while the socket connects to evil.com. Applying the
// same profile the transport uses closes that gap. A host the profile rejects
// is left as-is: canonicalAddr keeps the raw form on error too, so the raw
// comparison remains the accurate one.
func canonicalHost(h string) string {
	h = strings.ToLower(strings.Trim(h, "[]"))
	if ascii, err := idna.Lookup.ToASCII(h); err == nil {
		h = strings.ToLower(ascii)
	}
	// A trailing dot (evil.com.) is the DNS-absolute spelling of evil.com; a
	// leading dot (.evil.com) is the conventional wildcard spelling of a
	// blocklist entry. Trim both ends so the two sides of the suffix match in
	// hostAllowed line up regardless of which spelling either used.
	return strings.Trim(h, ".")
}

// hostAllowed validates a URL host string (the "host" or "host:port" from a
// parsed URL) against the optional domain blocklist. A domain entry blocks both
// itself and every subdomain at a label boundary (evil.com blocks
// img.evil.com, never notevil.com). The IP-level deny policy is enforced at dial
// time by the Control hook; this catches name-based blocklist entries (and
// IP-literal hosts that match a blocklist entry) up front.
func hostAllowed(host string, blocklist map[string]bool) error {
	h := host
	if hp, _, err := net.SplitHostPort(host); err == nil {
		h = hp
	}
	// parseBlocklist canonicalizes entries through the same helper, so an
	// operator entry and a request host always meet in the same namespace.
	h = canonicalHost(h)
	if h == "" {
		return fmt.Errorf("%w: empty host", errBlockedHost)
	}
	for blocked := range blocklist {
		if h == blocked || strings.HasSuffix(h, "."+blocked) {
			return fmt.Errorf("%w: destination matches blocklist", errBlockedHost)
		}
	}
	return nil
}
