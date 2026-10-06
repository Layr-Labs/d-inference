package mediawork

import (
	"context"
	"encoding/binary"

	encodedreader "github.com/eigeninference/d-inference/coordinator/internal/mediawork/encodedreader"
)

type atom struct {
	kind      string
	body, end int64
}
type movieReader struct {
	source *encodedreader.Reader
	atoms  int
}
type track struct {
	kind                  string
	width, height, frames int
	timescale             uint32
	ticks                 uint64
}

func (r *movieReader) children(start, end int64, visit func(atom) bool) bool {
	for start < end {
		r.atoms++
		if r.atoms > 4096 || end-start < 8 {
			return false
		}
		b, ok := r.source.Bytes(start, 8)
		if !ok {
			return false
		}
		n := int64(binary.BigEndian.Uint32(b))
		header := int64(8)
		if n == 1 {
			x, ok := r.source.Bytes(start+8, 8)
			if !ok {
				return false
			}
			u := binary.BigEndian.Uint64(x)
			if u > uint64(end-start) {
				return false
			}
			n = int64(u)
			header = 16
		} else if n == 0 {
			n = end - start
		}
		if n < header || n > end-start {
			return false
		}
		if !visit(atom{string(b[4:]), start + header, start + n}) {
			return false
		}
		start += n
	}
	return true
}

func (r *movieReader) read(a atom, n int) ([]byte, bool) {
	if int64(n) > a.end-a.body {
		return nil, false
	}
	return r.source.Bytes(a.body, n)
}

func (r *movieReader) parseTrack(a atom) (track, bool) {
	var t track
	ok := r.children(a.body, a.end, func(a atom) bool {
		if a.kind != "mdia" {
			return true
		}
		return r.children(a.body, a.end, func(a atom) bool {
			switch a.kind {
			case "hdlr":
				b, ok := r.read(a, 12)
				if !ok {
					return false
				}
				t.kind = string(b[8:12])
			case "mdhd":
				b, ok := r.read(a, 4)
				if !ok {
					return false
				}
				if b[0] == 0 {
					b, ok = r.read(a, 20)
					if !ok {
						return false
					}
					t.timescale = binary.BigEndian.Uint32(b[12:16])
				} else if b[0] == 1 {
					b, ok = r.read(a, 32)
					if !ok {
						return false
					}
					t.timescale = binary.BigEndian.Uint32(b[20:24])
				} else {
					return false
				}
			case "minf":
				return r.children(a.body, a.end, func(a atom) bool {
					if a.kind != "stbl" {
						return true
					}
					return r.children(a.body, a.end, func(a atom) bool { return r.sampleTable(a, &t) })
				})
			}
			return true
		})
	})
	return t, ok && t.timescale > 0 && t.ticks > 0
}

func (r *movieReader) sampleTable(a atom, t *track) bool {
	switch a.kind {
	case "stts":
		b, ok := r.read(a, 8)
		if !ok || t.frames != 0 {
			return false
		}
		entries := int(binary.BigEndian.Uint32(b[4:]))
		if entries <= 0 || entries > 16384 || int64(entries)*8 > a.end-a.body-8 {
			return false
		}
		for i := 0; i < entries; i++ {
			b, ok := r.source.Bytes(a.body+8+int64(i)*8, 8)
			if !ok {
				return false
			}
			n, d := uint64(binary.BigEndian.Uint32(b)), uint64(binary.BigEndian.Uint32(b[4:]))
			if n == 0 || d == 0 || n > 10_000_000 || uint64(t.frames)+n > 10_000_000 || n*d > 1<<53-t.ticks {
				return false
			}
			t.frames += int(n)
			t.ticks += n * d
		}
	case "stsd":
		b, ok := r.read(a, 8)
		if !ok || binary.BigEndian.Uint32(b[4:]) != 1 {
			return false
		}
		// A single visual sample description has stable decoded dimensions.
		entries := 0
		return r.children(a.body+8, a.end, func(entry atom) bool {
			entries++
			if entries != 1 {
				return false
			}
			switch entry.kind {
			case "avc1", "avc3", "hvc1", "hev1", "av01", "mp4v", "jpeg":
				b, ok := r.read(entry, 28)
				if !ok {
					return false
				}
				t.width = int(binary.BigEndian.Uint16(b[24:26]))
				t.height = int(binary.BigEndian.Uint16(b[26:28]))
			}
			return true
		})
	}
	return true
}

func (p *Profile) EncodedVideo(ctx context.Context, dataURI string) (int, bool) {
	s, ok := encodedreader.New(ctx, dataURI, false)
	if !ok {
		return 0, false
	}
	r := movieReader{source: s}
	var videos []track
	var audioDuration float64
	movie := false
	ok = r.children(0, s.Size(), func(a atom) bool {
		if a.kind == "moof" {
			return false
		} // Fragmented streams need a different sample table.
		if a.kind != "moov" {
			return true
		}
		if movie {
			return false
		}
		movie = true
		return r.children(a.body, a.end, func(a atom) bool {
			if a.kind != "trak" {
				return true
			}
			t, ok := r.parseTrack(a)
			if !ok {
				return false
			}
			if t.kind == "vide" {
				videos = append(videos, t)
			}
			if t.kind == "soun" {
				audioDuration = max(audioDuration, float64(t.ticks)/float64(t.timescale))
			}
			return len(videos) <= 1
		})
	})
	if !ok || !movie || len(videos) != 1 {
		return 0, false
	}
	v := videos[0]
	duration := float64(v.ticks) / float64(v.timescale)
	tokens, ok := p.VideoTokens(v.height, v.width, v.frames, duration)
	if !ok {
		return 0, false
	}
	if audioDuration > 0 {
		audio, ok := p.audioTokens(audioDuration)
		if !ok {
			return 0, false
		}
		// Each temporal visual group carries its own two audio wrapper tokens.
		chosen := min(max(duration*p.fps, float64((p.minFrames+1)/2*2)), float64(p.maxFrames/2*2), float64(v.frames))
		frames := int(chosen) / 2 * 2
		groups := (frames + p.temporal - 1) / p.temporal
		tokens += audio + 2*groups - 2
	}
	return tokens, true
}
