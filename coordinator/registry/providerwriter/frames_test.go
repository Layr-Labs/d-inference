package providerwriter

import (
	"context"
	"fmt"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// TestProviderWriterFragmentBoundaries checks the wire framing of
// writeFragmented across the fragment threshold: messages up to one fragment
// stay a single FIN text frame; larger ones become ceil(n/fragment) non-FIN
// frames (text, then continuation) of at most fragment bytes, terminated by
// nhooyr's zero-length FIN continuation — and always reassemble exactly.
func TestProviderWriterFragmentBoundaries(t *testing.T) {
	const f = fragmentBytes
	serverConnCh := make(chan *websocket.Conn, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			t.Errorf("accept websocket: %v", err)
			return
		}
		serverConnCh <- conn
		// Keep the handler (and the hijacked socket) alive; nothing is read.
		<-r.Context().Done()
	}))
	t.Cleanup(srv.Close)
	client := dialRawWS(t, srv.URL)
	var serverConn *websocket.Conn
	select {
	case serverConn = <-serverConnCh:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for server websocket")
	}
	w := New(serverConn)
	t.Cleanup(w.CloseNow)

	for _, size := range []int{0, 1, f - 1, f, f + 1, 3*f + 17} {
		t.Run(fmt.Sprintf("size=%d", size), func(t *testing.T) {
			data := make([]byte, size)
			rng := rand.New(rand.NewSource(int64(size)))
			for i := range data {
				data[i] = byte('a' + rng.Intn(26))
			}
			if err := w.Write(context.Background(), data); err != nil {
				t.Fatalf("write %d bytes: %v", size, err)
			}
			frames, err := client.readMessageFrames()
			if err != nil {
				t.Fatalf("read frames for %d bytes: %v (got %d frames)", size, err, len(frames))
			}

			var wantFrames int
			if size <= f {
				wantFrames = 1
			} else {
				wantFrames = (size+f-1)/f + 1
			}
			if len(frames) != wantFrames {
				t.Fatalf("frame count = %d, want %d", len(frames), wantFrames)
			}
			var joined []byte
			for i, fr := range frames {
				joined = append(joined, fr.payload...)
				last := i == len(frames)-1
				wantOpcode := byte(rawOpContinuation)
				if i == 0 {
					wantOpcode = rawOpText
				}
				if fr.opcode != wantOpcode {
					t.Fatalf("frame[%d] opcode = %#x, want %#x", i, fr.opcode, wantOpcode)
				}
				if fr.fin != last {
					t.Fatalf("frame[%d] fin = %v, want %v", i, fr.fin, last)
				}
				switch {
				case wantFrames == 1:
					if len(fr.payload) != size {
						t.Fatalf("single frame payload = %d, want %d", len(fr.payload), size)
					}
				case last:
					if len(fr.payload) != 0 {
						t.Fatalf("FIN continuation payload = %d, want 0", len(fr.payload))
					}
				case i == wantFrames-2:
					wantLast := size - (wantFrames-2)*f
					if len(fr.payload) != wantLast {
						t.Fatalf("last data fragment payload = %d, want %d", len(fr.payload), wantLast)
					}
				default:
					if len(fr.payload) != f {
						t.Fatalf("frame[%d] payload = %d, want %d", i, len(fr.payload), f)
					}
				}
			}
			if string(joined) != string(data) {
				t.Fatalf("reassembled %d bytes differ from the %d-byte message", len(joined), size)
			}
		})
	}
}
