package testkit

import (
	"math/rand/v2"
	"net"
	"strconv"
	"testing"
)

// FreeListenPort returns a port that is free on all interfaces, for an
// in-process coordinator that binds the port itself. The coordinator exits the
// process on a bind error, so the port comes from below the ephemeral ranges
// of macOS (49152+) and Linux (32768+), where outgoing connections and other
// tests' ":0" listeners cannot take it before the coordinator binds it.
func FreeListenPort(t testing.TB) string {
	t.Helper()
	for range 100 {
		port := strconv.Itoa(10000 + rand.IntN(22000))
		ln, err := net.Listen("tcp", ":"+port)
		if err != nil {
			continue
		}
		if err := ln.Close(); err != nil {
			t.Fatal(err)
		}
		return port
	}
	t.Fatal("no free port below the ephemeral range")
	return ""
}
