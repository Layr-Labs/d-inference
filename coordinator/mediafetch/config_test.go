package mediafetch

import (
	"strings"
	"testing"
	"time"
)

// TestConfigCheck pins the boot-time validation contract: every numeric bound
// must be positive and the per-file cap must fit inside the aggregate cap.
// sanitized() silently clamps the same fields, so Check is what turns an
// operator typo into a loud startup failure instead of a quiet revert to a
// default they did not ask for.
func TestConfigCheck(t *testing.T) {
	// mutate returns the production defaults with one field broken.
	mutate := func(f func(*Config)) Config {
		c := DefaultConfig()
		f(&c)
		return c
	}
	// wantMsg is the precise diagnostic, not just the field name: the
	// file-cap-vs-total-cap message mentions BOTH fields, so a loose field-name
	// match would let a missing "MaxTotalBytes must be > 0" branch hide behind
	// it.
	cases := []struct {
		name    string
		cfg     Config
		wantMsg string // substring the error must contain; "" = must pass
	}{
		{"defaults are valid", DefaultConfig(), ""},
		{"disabled defaults are still valid", mutate(func(c *Config) { c.Enabled = false }), ""},
		{"private-IP override is a WARN, not an error", mutate(func(c *Config) { c.AllowPrivateIPs = true }), ""},
		{"nonstandard-port override is a WARN, not an error", mutate(func(c *Config) { c.AllowNonStandardPorts = true }), ""},
		{"zero MaxFileBytes", mutate(func(c *Config) { c.MaxFileBytes = 0 }), "MaxFileBytes must be > 0"},
		{"negative MaxFileBytes", mutate(func(c *Config) { c.MaxFileBytes = -1 }), "MaxFileBytes must be > 0"},
		{"zero MaxTotalBytes", mutate(func(c *Config) { c.MaxTotalBytes = 0 }), "MaxTotalBytes must be > 0"},
		{"file cap above total cap", mutate(func(c *Config) { c.MaxFileBytes = c.MaxTotalBytes + 1 }), "must be <= MaxTotalBytes"},
		{"zero MaxInlinedBytes", mutate(func(c *Config) { c.MaxInlinedBytes = 0 }), "MaxInlinedBytes must be > 0"},
		{"zero MaxParts", mutate(func(c *Config) { c.MaxParts = 0 }), "MaxParts must be > 0"},
		{"zero FetchTimeout", mutate(func(c *Config) { c.FetchTimeout = 0 }), "FetchTimeout must be > 0"},
		{"negative FetchTimeout", mutate(func(c *Config) { c.FetchTimeout = -time.Second }), "FetchTimeout must be > 0"},
		{"zero TotalDeadline", mutate(func(c *Config) { c.TotalDeadline = 0 }), "TotalDeadline must be > 0"},
		{"zero Concurrency", mutate(func(c *Config) { c.Concurrency = 0 }), "Concurrency must be > 0"},
		{"zero GlobalConcurrency", mutate(func(c *Config) { c.GlobalConcurrency = 0 }), "GlobalConcurrency must be > 0"},
	}
	for _, c := range cases {
		err := c.cfg.Check()
		switch {
		case c.wantMsg == "" && err != nil:
			t.Errorf("%s: Check() = %v, want nil", c.name, err)
		case c.wantMsg != "" && err == nil:
			t.Errorf("%s: Check() = nil, want an error containing %q", c.name, c.wantMsg)
		case c.wantMsg != "" && !strings.Contains(err.Error(), c.wantMsg):
			t.Errorf("%s: Check() = %v, want the error to contain %q", c.name, err, c.wantMsg)
		}
	}
}

// TestParseBlocklistCanonicalizesEntries covers the leading-dot wildcard
// spelling. ".evil.com" is the conventional way operators write "this domain
// and everything under it"; trimming only the trailing dot stored a key
// hostAllowed could never match (it would need a literal "..evil.com" suffix),
// silently disabling the entry. Reverting the leading-dot trim flips both
// dotted-entry rows below to allowed.
func TestParseBlocklistCanonicalizesEntries(t *testing.T) {
	cases := []struct {
		name  string
		entry string
	}{
		{"bare domain", "evil.com"},
		{"leading-dot wildcard spelling", ".evil.com"},
		{"trailing FQDN dot", "evil.com."},
		{"both ends dotted", ".evil.com."},
		{"uppercase with surrounding space", "  EVIL.COM  "},
		{"unicode separator", "evil\u3002com"},
	}
	for _, c := range cases {
		bl := parseBlocklist(c.entry)
		if !bl["evil.com"] {
			t.Errorf("%s: parseBlocklist(%q) = %v, want the canonical key evil.com", c.name, c.entry, bl)
			continue
		}
		for _, host := range []string{"evil.com", "img.evil.com"} {
			if err := hostAllowed(host, bl); err == nil {
				t.Errorf("%s: entry %q must block %q", c.name, c.entry, host)
			}
		}
		if err := hostAllowed("notevil.com", bl); err != nil {
			t.Errorf("%s: entry %q must not block notevil.com: %v", c.name, c.entry, err)
		}
	}

	// A list of only separators/whitespace must not store an empty key — an
	// empty key would suffix-match every host and black-hole all media.
	for _, csv := range []string{"", " , , ", ".", "..", " . "} {
		if bl := parseBlocklist(csv); len(bl) != 0 {
			t.Errorf("parseBlocklist(%q) = %v, want an empty set", csv, bl)
		}
	}
}
