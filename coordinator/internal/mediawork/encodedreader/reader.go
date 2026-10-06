package encodedreader

import (
	"context"
	"encoding/base64"
	"errors"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"strings"
)

const MaxEncodedBytes = 64 << 20

var errMetadata = errors.New("media metadata unavailable")

// encodedSource decodes only requested base64 blocks. Skipping a video's mdat
// never allocates or scans its frame payloads. Parsing has a separate byte cap.
type Reader struct {
	ctx       context.Context
	text      string
	size      int64
	readBytes int
}

func New(ctx context.Context, text string, raw bool) (*Reader, bool) {
	if !raw {
		meta, body, ok := strings.Cut(text, ",")
		if !ok || len(meta) > 256 || !strings.HasPrefix(meta, "data:") || !strings.HasSuffix(meta, ";base64") {
			return nil, false
		}
		text = body
	}
	if len(text) == 0 || len(text)%4 != 0 || len(text) > base64.StdEncoding.EncodedLen(MaxEncodedBytes) {
		return nil, false
	}
	n := int64(len(text) / 4 * 3)
	if strings.HasSuffix(text, "==") {
		n -= 2
	} else if strings.HasSuffix(text, "=") {
		n--
	}
	if n > MaxEncodedBytes {
		return nil, false
	}
	return &Reader{ctx: ctx, text: text, size: n}, true
}

func (s *Reader) ReadAt(dst []byte, off int64) (int, error) {
	if s.ctx.Err() != nil {
		return 0, s.ctx.Err()
	}
	if off < 0 || len(dst) > 1<<20 || s.readBytes+len(dst) > 1<<20 {
		return 0, errMetadata
	}
	if len(dst) == 0 {
		return 0, nil
	}
	if off >= s.size {
		return 0, io.EOF
	}
	n := min(int64(len(dst)), s.size-off)
	start := off / 3 * 4
	end := min(int64(len(s.text)), (off+n+2)/3*4)
	decoded, err := base64.StdEncoding.DecodeString(s.text[start:end])
	if err != nil {
		return 0, errMetadata
	}
	begin := off - off/3*3
	if begin+n > int64(len(decoded)) {
		return 0, errMetadata
	}
	copy(dst, decoded[begin:begin+n])
	s.readBytes += int(n)
	if n < int64(len(dst)) {
		return int(n), io.EOF
	}
	return int(n), nil
}

func (s *Reader) Bytes(off int64, n int) ([]byte, bool) {
	if n <= 0 || n > 1<<20 {
		return nil, false
	}
	b := make([]byte, n)
	_, err := s.ReadAt(b, off)
	return b, err == nil
}

func (s *Reader) Size() int64 { return s.size }
