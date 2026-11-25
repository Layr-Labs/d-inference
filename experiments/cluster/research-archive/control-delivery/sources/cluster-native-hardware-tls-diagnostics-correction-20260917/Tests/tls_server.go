// Actual loopback TLS/WebSocket fixture. No trust-store writes or production keys.
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"
)

type observedListener struct {
	net.Listener
	accepted *atomic.Int64
}

func (l observedListener) Accept() (net.Conn, error) {
	c, e := l.Listener.Accept()
	if e == nil {
		l.accepted.Add(1)
	}
	return c, e
}

func must[T any](v T, e error) T {
	if e != nil {
		panic(e)
	}
	return v
}
func main() {
	if len(os.Args) != 2 {
		panic("one fresh fixture directory required")
	}
	root := os.Args[1]
	if !filepath.IsAbs(root) {
		panic("absolute fixture directory required")
	}
	info := must(os.Stat(root))
	if !info.IsDir() {
		panic("fixture directory")
	}
	write := func(name string, b []byte) {
		f := must(os.OpenFile(filepath.Join(root, name), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600))
		if _, e := f.Write(b); e != nil {
			panic(e)
		}
		if e := f.Close(); e != nil {
			panic(e)
		}
	}
	now := time.Now()
	caKey := must(ecdsa.GenerateKey(elliptic.P256(), rand.Reader))
	ca := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "private TLS fixture CA"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(2 * time.Hour), IsCA: true, BasicConstraintsValid: true, MaxPathLen: 0, MaxPathLenZero: true, KeyUsage: x509.KeyUsageCertSign}
	caDER := must(x509.CreateCertificate(rand.Reader, ca, ca, &caKey.PublicKey, caKey))
	write("ca.der", caDER)
	otherKey := must(ecdsa.GenerateKey(elliptic.P256(), rand.Reader))
	other := *ca
	other.SerialNumber = big.NewInt(2)
	other.Subject.CommonName = "different fixture CA"
	write("wrong-ca.der", must(x509.CreateCertificate(rand.Reader, &other, &other, &otherKey.PublicKey, otherKey)))
	ports := map[string]int{}
	counts := map[string]*atomic.Int64{}
	tcpCounts := map[string]*atomic.Int64{}
	servers := []*http.Server{}
	for i, mode := range []string{"valid", "wrong-host", "expired"} {
		key := must(ecdsa.GenerateKey(elliptic.P256(), rand.Reader))
		dns := "localhost"
		before := now.Add(-time.Hour)
		after := now.Add(time.Hour)
		if mode == "wrong-host" {
			dns = "wrong.invalid"
		}
		if mode == "expired" {
			before = now.Add(-48 * time.Hour)
			after = now.Add(-24 * time.Hour)
		}
		leaf := &x509.Certificate{SerialNumber: big.NewInt(int64(10 + i)), Subject: pkix.Name{CommonName: dns}, DNSNames: []string{dns}, NotBefore: before, NotAfter: after, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true}
		der := must(x509.CreateCertificate(rand.Reader, leaf, ca, &key.PublicKey, caKey))
		listener := must(net.Listen("tcp", "127.0.0.1:0"))
		ports[mode] = listener.Addr().(*net.TCPAddr).Port
		count := new(atomic.Int64)
		counts[mode] = count
		handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.TLS == nil || r.URL.Path != "/ws" || r.Header.Get("Upgrade") != "websocket" || r.Header.Get("Sec-WebSocket-Version") != "13" {
				http.Error(w, "refused", 400)
				return
			}
			key := r.Header.Get("Sec-WebSocket-Key")
			if key == "" {
				http.Error(w, "missing key", 400)
				return
			}
			connection, buffer, e := w.(http.Hijacker).Hijack()
			if e != nil {
				return
			}
			defer connection.Close()
			if e = connection.SetDeadline(time.Now().Add(5 * time.Second)); e != nil {
				return
			}
			sum := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
			fmt.Fprintf(buffer, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", base64.StdEncoding.EncodeToString(sum[:]))
			if e = buffer.Flush(); e != nil {
				return
			}
			count.Add(1)
			// Hold the real upgraded TLS socket until the client cancels or deadline.
			one := make([]byte, 1)
			_, _ = buffer.Read(one)
		})
		server := &http.Server{Handler: handler, ReadHeaderTimeout: 3 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 5 * time.Second, ErrorLog: log.New(os.Stderr, "fixture TLS: ", 0)}
		servers = append(servers, server)
		tcpCount := new(atomic.Int64)
		tcpCounts[mode] = tcpCount
		wrapped := tls.NewListener(observedListener{listener, tcpCount}, &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{{Certificate: [][]byte{der, caDER}, PrivateKey: key}}})
		go func(s *http.Server, l net.Listener) {
			if e := s.Serve(l); e != nil && !errors.Is(e, http.ErrServerClosed) {
				panic(e)
			}
		}(server, wrapped)
	}
	write("ready.pending", must(json.Marshal(ports)))
	if e := os.Rename(filepath.Join(root, "ready.pending"), filepath.Join(root, "ready.json")); e != nil {
		panic(e)
	}
	// Owned supervisor keeps stdin open; bounded 40s lifetime is independent.
	done := make(chan struct{})
	go func() { one := make([]byte, 1); _, _ = os.Stdin.Read(one); close(done) }()
	select {
	case <-done:
	case <-time.After(40 * time.Second):
	}
	for _, server := range servers {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = server.Shutdown(ctx)
		cancel()
	}
	result := map[string]int64{}
	for mode, count := range counts {
		result[mode] = count.Load()
	}
	write("server-result.json", must(json.Marshal(result)))
	tcpResult := map[string]int64{}
	for mode, count := range tcpCounts {
		tcpResult[mode] = count.Load()
	}
	write("server-tcp-observation.json", must(json.Marshal(tcpResult)))
}
