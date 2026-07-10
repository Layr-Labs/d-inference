package mediafetch

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"net/http"
	"strings"
	"testing"
)

// --- fixtures ----------------------------------------------------------------

// validPNG / validJPEG / validGIF are real, decodable 2x2 images produced by the
// stdlib encoders — they pass both the sniff allowlist AND the header pixel gate.
func validPNG(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatalf("encode png: %v", err)
	}
	return buf.Bytes()
}

func validJPEG(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 2, 2)), nil); err != nil {
		t.Fatalf("encode jpeg: %v", err)
	}
	return buf.Bytes()
}

func validGIF(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	pal := color.Palette{color.Black, color.White}
	if err := gif.Encode(&buf, image.NewPaletted(image.Rect(0, 0, 2, 2), pal), nil); err != nil {
		t.Fatalf("encode gif: %v", err)
	}
	return buf.Bytes()
}

// mp4Bytes returns bytes http.DetectContentType sniffs as video/mp4: an ISO-BMFF
// ftyp box (size 20) with major brand mp42.
func mp4Bytes(total int) []byte {
	head := append([]byte{0, 0, 0, 20}, []byte("ftypmp42\x00\x00\x00\x00mp42")...)
	if total < len(head) {
		total = len(head)
	}
	b := make([]byte, total)
	copy(b, head)
	return b
}

// quickTimeBytes returns an ftyp box with the QuickTime major brand ("qt  "),
// which DetectContentType does NOT classify — our custom sniff must.
func quickTimeBytes(total int) []byte {
	head := append([]byte{0, 0, 0, 20}, []byte("ftypqt  \x00\x00\x00\x00qt  ")...)
	if total < len(head) {
		total = len(head)
	}
	b := make([]byte, total)
	copy(b, head)
	return b
}

// bombPNG hand-crafts a syntactically valid PNG header (correct IHDR CRC)
// declaring width×height = 20000×20000 = 400 MP — a pixel bomb whose FILE size
// is tiny. png.DecodeConfig reads exactly this header.
func bombPNG(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	buf.WriteString("\x89PNG\r\n\x1a\n")
	ihdr := make([]byte, 13)
	binary.BigEndian.PutUint32(ihdr[0:4], 20000) // width
	binary.BigEndian.PutUint32(ihdr[4:8], 20000) // height
	ihdr[8] = 8                                  // bit depth
	ihdr[9] = 6                                  // color type RGBA
	// compression/filter/interlace = 0
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], 13)
	buf.Write(length[:])
	chunk := append([]byte("IHDR"), ihdr...)
	buf.Write(chunk)
	var crc [4]byte
	binary.BigEndian.PutUint32(crc[:], crc32.ChecksumIEEE(chunk))
	buf.Write(crc[:])
	return buf.Bytes()
}

// --- tests ---------------------------------------------------------------

func TestSniffMediaType(t *testing.T) {
	cases := []struct {
		name     string
		data     []byte
		wantMime string
		wantKind mediaKind
		wantOK   bool
	}{
		{"png", []byte("\x89PNG\r\n\x1a\n................"), "image/png", kindImage, true},
		{"jpeg", []byte("\xff\xd8\xff\xe0................"), "image/jpeg", kindImage, true},
		{"gif", []byte("GIF89a................"), "image/gif", kindImage, true},
		{"webp", []byte("RIFF\x00\x00\x00\x00WEBPVP8 ........"), "image/webp", kindImage, true},
		{"bmp", []byte("BM.............................."), "image/bmp", kindImage, true},
		{"mp4", mp4Bytes(32), "video/mp4", kindVideo, true},
		{"quicktime", quickTimeBytes(32), "video/quicktime", kindVideo, true},

		// Formats the provider cannot decode (AVFoundation has no WebM/AVI) and
		// non-media content must fail the allowlist.
		{"webm rejected", []byte("\x1aE\xdf\xa3................"), "", "", false},
		{"avi rejected", []byte("RIFF\x00\x00\x00\x00AVI ............"), "", "", false},
		{"html", []byte("<!DOCTYPE html><html></html>"), "", "", false},
		{"svg-as-xml", []byte("<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"/>"), "", "", false},
		{"text", []byte("just some text here, not media"), "", "", false},
		{"elf executable", []byte("\x7fELF............................"), "", "", false},
		{"empty", []byte{}, "", "", false},
	}
	for _, c := range cases {
		mime, kind, ok := sniffMediaType(c.data)
		if mime != c.wantMime || kind != c.wantKind || ok != c.wantOK {
			t.Errorf("sniffMediaType(%s) = (%q,%q,%v), want (%q,%q,%v)",
				c.name, mime, kind, ok, c.wantMime, c.wantKind, c.wantOK)
		}
	}
}

func TestValidateFetchedMediaKindMismatch(t *testing.T) {
	r := NewResolver(DefaultConfig(), nil)
	// An image_url part resolving to a video must be rejected (and vice versa).
	if _, err := r.validateFetchedMedia(kindImage, mp4Bytes(32)); err == nil {
		t.Fatal("image_url→mp4 must be rejected")
	} else if me := err.(*Error); me.Code != "media_kind_mismatch" || me.Status != http.StatusBadRequest {
		t.Errorf("got %d/%s, want 400/media_kind_mismatch", me.Status, me.Code)
	}
	if _, err := r.validateFetchedMedia(kindVideo, validPNG(t)); err == nil {
		t.Fatal("video_url→png must be rejected")
	} else if me := err.(*Error); me.Code != "media_kind_mismatch" {
		t.Errorf("got %s, want media_kind_mismatch", me.Code)
	}
	// Matching kinds pass and return the sniffed mime.
	mime, err := r.validateFetchedMedia(kindImage, validJPEG(t))
	if err != nil || mime != "image/jpeg" {
		t.Errorf("valid jpeg: mime=%q err=%v", mime, err)
	}
	if mime, err := r.validateFetchedMedia(kindVideo, quickTimeBytes(32)); err != nil || mime != "video/quicktime" {
		t.Errorf("quicktime: mime=%q err=%v", mime, err)
	}
}

func TestPixelCapRejectsBomb(t *testing.T) {
	r := NewResolver(DefaultConfig(), nil) // 100 MP default cap
	_, err := r.validateFetchedMedia(kindImage, bombPNG(t))
	if err == nil {
		t.Fatal("400 MP png header must be rejected")
	}
	me := err.(*Error)
	if me.Code != "media_too_large" || me.Status != http.StatusRequestEntityTooLarge {
		t.Errorf("got %d/%s, want 413/media_too_large", me.Status, me.Code)
	}
}

func TestPixelCapAcceptsNormalImagesAndSkipsHeaderlessFormats(t *testing.T) {
	r := NewResolver(DefaultConfig(), nil)
	for name, data := range map[string][]byte{
		"png": validPNG(t), "jpeg": validJPEG(t), "gif": validGIF(t),
	} {
		if _, err := r.validateFetchedMedia(kindImage, data); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	// BMP/WebP have no stdlib header decoder: the pixel gate is skipped (the
	// provider's own pre-raster cap covers them) and the bytes still inline.
	if mime, err := r.validateFetchedMedia(kindImage, []byte("BM..............................")); err != nil || mime != "image/bmp" {
		t.Errorf("bmp: mime=%q err=%v", mime, err)
	}
}

func TestPixelCapRejectsCorruptHeader(t *testing.T) {
	r := NewResolver(DefaultConfig(), nil)
	// Sniffs as PNG (magic bytes) but the IHDR is garbage — the provider's
	// decoder would fail on it, so it must fail fast here.
	corrupt := []byte("\x89PNG\r\n\x1a\n................")
	_, err := r.validateFetchedMedia(kindImage, corrupt)
	if err == nil {
		t.Fatal("corrupt png header must be rejected")
	}
	if me := err.(*Error); me.Code != "media_invalid_type" {
		t.Errorf("got %s, want media_invalid_type", me.Code)
	}
}

func TestPixelCapDisabled(t *testing.T) {
	cfg := DefaultConfig()
	cfg.MaxImageMegapixels = 0 // explicit off → header parse skipped entirely
	r := NewResolver(cfg, nil)
	if _, err := r.validateFetchedMedia(kindImage, bombPNG(t)); err != nil {
		t.Errorf("cap disabled: bomb header should pass to the provider layer, got %v", err)
	}
}

func TestToDataURI(t *testing.T) {
	got := toDataURI(&fetchedMedia{mime: "image/png", data: []byte("AB")})
	want := "data:image/png;base64,QUI="
	if got != want {
		t.Errorf("toDataURI = %q, want %q", got, want)
	}
}

func TestQuickTimeSniffTooShort(t *testing.T) {
	if isQuickTime([]byte("\x00\x00\x00\x14ftypqt")) {
		t.Error("11-byte prefix must not classify as QuickTime")
	}
	if _, _, ok := sniffMediaType([]byte("\x00\x00\x00\x14ftyp")); ok {
		t.Error("bare ftyp must not pass the allowlist")
	}
}

// Guard: no allowlisted type may be outside image/* or video/* (the Accept
// header and kind cross-check assume the two families).
func TestAllowlistFamilies(t *testing.T) {
	for mime, kind := range allowedSniffedTypes {
		wantPrefix := string(kind) + "/"
		if !strings.HasPrefix(mime, wantPrefix) {
			t.Errorf("allowlist entry %q maps to kind %q but lacks prefix %q", mime, kind, wantPrefix)
		}
	}
}
