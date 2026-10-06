package mediawork_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"image"
	"image/png"
	"io"
	"testing"

	encodedreader "github.com/eigeninference/d-inference/coordinator/internal/mediawork/encodedreader"
)

func uri(kind string, b []byte) string {
	return "data:" + kind + ";base64," + base64.StdEncoding.EncodeToString(b)
}

func TestEncodedReaderAlignmentAndCancellation(t *testing.T) {
	for size := 1; size < 80; size++ {
		data := make([]byte, size)
		for i := range data {
			data[i] = byte(i)
		}
		s, ok := encodedreader.New(context.Background(), uri("x", data), false)
		if !ok {
			t.Fatal("source")
		}
		for off := range size {
			for n := 1; n <= 7; n++ {
				got := make([]byte, n)
				count, err := s.ReadAt(got, int64(off))
				want := data[off:min(size, off+n)]
				if count != len(want) || !bytes.Equal(got[:count], want) || (len(want) < n && err != io.EOF) || (len(want) == n && err != nil) {
					t.Fatalf("size%d off%d len%d got%v err%v", size, off, n, got, err)
				}
			}
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	s, _ := encodedreader.New(ctx, uri("x", []byte("bytes")), false)
	if _, err := s.ReadAt(make([]byte, 1), 0); err == nil {
		t.Fatal("cancel ignored")
	}
	if _, ok := encodedreader.New(context.Background(), "https://example.invalid/media", false); ok {
		t.Fatal("remote URL accepted")
	}
}

func TestEncodedImageAndWaveCounts(t *testing.T) {
	p := testProfile(t)
	var b bytes.Buffer
	if err := png.Encode(&b, image.NewRGBA(image.Rect(0, 0, 1280, 851))); err != nil {
		t.Fatal(err)
	}
	if n, ok := p.EncodedImage(context.Background(), uri("image/png", b.Bytes())); !ok || n != 1082 {
		t.Fatalf("image%d,%v", n, ok)
	}
	wav := make([]byte, 44+22050)
	copy(wav, "RIFF")
	binary.LittleEndian.PutUint32(wav[4:], uint32(len(wav)-8))
	copy(wav[8:], "WAVEfmt ")
	binary.LittleEndian.PutUint32(wav[16:], 16)
	binary.LittleEndian.PutUint16(wav[20:], 1)
	binary.LittleEndian.PutUint16(wav[22:], 1)
	binary.LittleEndian.PutUint32(wav[24:], 22050)
	binary.LittleEndian.PutUint32(wav[28:], 22050)
	binary.LittleEndian.PutUint16(wav[32:], 1)
	binary.LittleEndian.PutUint16(wav[34:], 8)
	copy(wav[36:], "data")
	binary.LittleEndian.PutUint32(wav[40:], 22050)
	if n, ok := p.EncodedAudio(context.Background(), base64.StdEncoding.EncodeToString(wav), true); !ok || n != 9 {
		t.Fatalf("wav%d,%v", n, ok)
	}
	binary.LittleEndian.PutUint16(wav[32:], 2)
	if _, ok := p.EncodedAudio(context.Background(), uri("audio/wav", wav), false); ok {
		t.Fatal("malformed PCM alignment accepted")
	}
}
