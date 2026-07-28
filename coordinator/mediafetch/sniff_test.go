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

// webPVP8XBytes builds a VP8X header with the requested canvas dimensions.
// Pixel payload is unnecessary: the coordinator validates headers only and the
// provider remains the authoritative full decoder.
func webPVP8XBytes(width, height int) []byte {
	b := make([]byte, 30)
	copy(b[0:4], "RIFF")
	binary.LittleEndian.PutUint32(b[4:8], uint32(len(b)-8))
	copy(b[8:12], "WEBP")
	copy(b[12:16], "VP8X")
	binary.LittleEndian.PutUint32(b[16:20], 10)
	w := width - 1
	h := height - 1
	b[24], b[25], b[26] = byte(w), byte(w>>8), byte(w>>16)
	b[27], b[28], b[29] = byte(h), byte(h>>8), byte(h>>16)
	return b
}

func webPVP8LBytes(width, height int) []byte {
	b := make([]byte, 25)
	copy(b[0:4], "RIFF")
	binary.LittleEndian.PutUint32(b[4:8], uint32(len(b)-8))
	copy(b[8:12], "WEBP")
	copy(b[12:16], "VP8L")
	binary.LittleEndian.PutUint32(b[16:20], 5)
	b[20] = 0x2f
	packed := uint32(width-1) | uint32(height-1)<<14
	binary.LittleEndian.PutUint32(b[21:25], packed)
	return b
}

func webPVP8Bytes(width, height int) []byte {
	b := make([]byte, 30)
	copy(b[0:4], "RIFF")
	binary.LittleEndian.PutUint32(b[4:8], uint32(len(b)-8))
	copy(b[8:12], "WEBP")
	copy(b[12:16], "VP8 ")
	binary.LittleEndian.PutUint32(b[16:20], 10)
	copy(b[23:26], []byte{0x9d, 0x01, 0x2a})
	binary.LittleEndian.PutUint16(b[26:28], uint16(width))
	binary.LittleEndian.PutUint16(b[28:30], uint16(height))
	return b
}

// bmpBytes builds a Windows BITMAPINFOHEADER with the requested dimensions.
func bmpBytes(width, height int32) []byte {
	b := make([]byte, 54)
	copy(b[0:2], "BM")
	binary.LittleEndian.PutUint32(b[2:6], uint32(len(b)))
	binary.LittleEndian.PutUint32(b[10:14], 54)
	binary.LittleEndian.PutUint32(b[14:18], 40)
	binary.LittleEndian.PutUint32(b[18:22], uint32(width))
	binary.LittleEndian.PutUint32(b[22:26], uint32(height))
	binary.LittleEndian.PutUint16(b[26:28], 1)
	binary.LittleEndian.PutUint16(b[28:30], 24)
	return b
}

func bmpCoreBytes(width, height uint16) []byte {
	b := make([]byte, 26)
	copy(b[0:2], "BM")
	binary.LittleEndian.PutUint32(b[2:6], uint32(len(b)))
	binary.LittleEndian.PutUint32(b[14:18], 12)
	binary.LittleEndian.PutUint16(b[18:20], width)
	binary.LittleEndian.PutUint16(b[20:22], height)
	return b
}

func bmpOS2Bytes(dibSize uint32, width, height uint32) []byte {
	b := make([]byte, 30)
	copy(b[0:2], "BM")
	binary.LittleEndian.PutUint32(b[2:6], uint32(len(b)))
	binary.LittleEndian.PutUint32(b[14:18], dibSize)
	binary.LittleEndian.PutUint32(b[18:22], width)
	binary.LittleEndian.PutUint32(b[22:26], height)
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
		{"webp", webPVP8XBytes(2, 2), "image/webp", kindImage, true},
		{"bmp", bmpBytes(2, 2), "image/bmp", kindImage, true},
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

func TestPixelCapAcceptsAllNormalImageFormats(t *testing.T) {
	r := NewResolver(DefaultConfig(), nil)
	for name, data := range map[string][]byte{
		"png": validPNG(t), "jpeg": validJPEG(t), "gif": validGIF(t),
		"webp-vp8x":     webPVP8XBytes(2, 2),
		"webp-vp8l":     webPVP8LBytes(2, 2),
		"webp-vp8":      webPVP8Bytes(2, 2),
		"bmp-info":      bmpBytes(2, 2),
		"bmp-top-down":  bmpBytes(2, -2),
		"bmp-core":      bmpCoreBytes(2, 2),
		"bmp-os2-short": bmpOS2Bytes(16, 2, 2),
		"bmp-os2-full":  bmpOS2Bytes(64, 2, 2),
	} {
		if _, err := r.validateFetchedMedia(kindImage, data); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestPixelCapRejectsWebPAndBMPBombs(t *testing.T) {
	r := NewResolver(DefaultConfig(), nil)
	for name, data := range map[string][]byte{
		"webp-vp8x":                webPVP8XBytes(20_000, 20_000),
		"webp-vp8l":                webPVP8LBytes(12_000, 12_000),
		"webp-vp8":                 webPVP8Bytes(12_000, 12_000),
		"bmp-info":                 bmpBytes(20_000, 20_000),
		"bmp-core":                 bmpCoreBytes(20_000, 20_000),
		"bmp-os2-product-overflow": bmpOS2Bytes(16, ^uint32(0), ^uint32(0)),
	} {
		_, err := r.validateFetchedMedia(kindImage, data)
		if err == nil {
			t.Errorf("%s 400 MP header must be rejected", name)
			continue
		}
		if me := err.(*Error); me.Code != "media_too_large" {
			t.Errorf("%s: got %s, want media_too_large", name, me.Code)
		}
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
	nearMatch := quickTimeBytes(32)
	copy(nearMatch[8:12], "qtxx")
	if isQuickTime(nearMatch) {
		t.Error("only the exact QuickTime major brand \"qt  \" may match")
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
