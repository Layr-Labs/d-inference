package mediawork

import (
	"context"
	"encoding/binary"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"math"

	encodedreader "github.com/eigeninference/d-inference/coordinator/internal/mediawork/encodedreader"
)

func (p *Profile) EncodedImage(ctx context.Context, dataURI string) (int, bool) {
	s, ok := encodedreader.New(ctx, dataURI, false)
	if !ok {
		return 0, false
	}
	c, _, err := image.DecodeConfig(io.NewSectionReader(s, 0, min(s.Size(), 1<<20)))
	if err != nil {
		return 0, false
	}
	return p.ImageTokens(c.Height, c.Width)
}

func (p *Profile) audioTokens(duration float64) (int, bool) {
	if p == nil || !p.audio || duration <= 0 || duration > 86400 || math.IsNaN(duration) || math.IsInf(duration, 0) {
		return 0, false
	}
	// Native resampling -> centered STFT (+1) -> two stride-2 stages ->
	// groups of four codes. 6000-frame segment boundaries divide evenly by4.
	frames := int(math.Ceil(duration * 24000))
	mel := frames/240 + 1
	codes := (mel + 3) / 4
	return (codes+3)/4 + 2, true
}

func (p *Profile) EncodedAudio(ctx context.Context, encoded string, raw bool) (int, bool) {
	s, ok := encodedreader.New(ctx, encoded, raw)
	if !ok {
		return 0, false
	}
	b, ok := s.Bytes(0, 12)
	if !ok || string(b[:4]) != "RIFF" || string(b[8:]) != "WAVE" {
		return 0, false
	}
	end := int64(binary.LittleEndian.Uint32(b[4:8])) + 8
	if end > s.Size() || end < 12 {
		return 0, false
	}
	var rate, align uint32
	var dataBytes int64
	for off, parts := int64(12), 0; off+8 <= end; parts++ {
		if parts >= 4096 {
			return 0, false
		}
		h, ok := s.Bytes(off, 8)
		if !ok {
			return 0, false
		}
		n := int64(binary.LittleEndian.Uint32(h[4:]))
		start := off + 8
		if n > end-start {
			return 0, false
		}
		switch string(h[:4]) {
		case "fmt ":
			if rate != 0 || n < 16 {
				return 0, false
			}
			f, ok := s.Bytes(start, 16)
			if !ok {
				return 0, false
			}
			format := binary.LittleEndian.Uint16(f)
			if format != 1 && format != 3 {
				return 0, false
			}
			rate = binary.LittleEndian.Uint32(f[4:8])
			align = uint32(binary.LittleEndian.Uint16(f[12:14]))
			channels := uint32(binary.LittleEndian.Uint16(f[2:4]))
			bits := uint32(binary.LittleEndian.Uint16(f[14:16]))
			if channels == 0 || channels > 64 || rate == 0 || rate > 768000 ||
				(bits != 8 && bits != 16 && bits != 24 && bits != 32 && bits != 64) ||
				(format == 3 && bits != 32 && bits != 64) || align != channels*(bits/8) ||
				binary.LittleEndian.Uint32(f[8:12]) != rate*align {
				return 0, false
			}
		case "data":
			dataBytes += n
		}
		off = start + n + n%2
	}
	if rate == 0 || align == 0 || dataBytes == 0 || dataBytes%int64(align) != 0 {
		return 0, false
	}
	return p.audioTokens(float64(dataBytes/int64(align)) / float64(rate))
}
