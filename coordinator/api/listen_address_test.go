package api

import "testing"

func TestListenAddressPreservesDefaultAndSupportsLiteralHosts(t *testing.T) {
	for _, test := range []struct{ host, address string }{
		{"", ":8080"}, {"127.0.0.1", "127.0.0.1:8080"}, {"::1", "[::1]:8080"},
		{"0.0.0.0", "0.0.0.0:8080"}, {"::", "[::]:8080"},
	} {
		config := ServerConfig{Port: "8080", BindHost: test.host}
		if err := config.Check(); err != nil {
			t.Fatalf("host %q: %v", test.host, err)
		}
		if got := config.ListenAddress(); got != test.address {
			t.Fatalf("address=%q want=%q", got, test.address)
		}
	}
	for _, host := range []string{"localhost", "127.0.0.1:8080", "[::1]", " ::1", "fe80::1%en0", "bad-host"} {
		if err := (ServerConfig{BindHost: host}).Check(); err == nil {
			t.Fatalf("invalid host %q accepted", host)
		}
	}
}

func TestListenAddressReadsExplicitHostWithoutChangingDefault(t *testing.T) {
	t.Setenv("EIGENINFERENCE_BIND_HOST", "")
	t.Setenv("EIGENINFERENCE_PORT", "8123")
	if got := ReadServerConfig().ListenAddress(); got != ":8123" {
		t.Fatalf("default changed: %s", got)
	}
	t.Setenv("EIGENINFERENCE_BIND_HOST", "127.0.0.1")
	if got := ReadServerConfig().ListenAddress(); got != "127.0.0.1:8123" {
		t.Fatalf("loopback not applied: %s", got)
	}
}
