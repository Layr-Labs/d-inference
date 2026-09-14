package api

import (
	"errors"
	"net"
)

// ListenAddress preserves the historical all-interface bind when BindHost is
// empty. A literal host permits isolated loopback acceptance using real main.
func (c ServerConfig) ListenAddress() string {
	return net.JoinHostPort(c.BindHost, c.Port)
}

func (c ServerConfig) checkBindHost() error {
	if c.BindHost != "" && net.ParseIP(c.BindHost) == nil {
		return errors.New("EIGENINFERENCE_BIND_HOST must be empty or an IP literal")
	}
	return nil
}
