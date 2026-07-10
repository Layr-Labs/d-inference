package mediafetch

// sniff.go decides what fetched bytes actually ARE — from magic bytes, never the
// spoofable Content-Type header — and enforces the structural safety policy on
// them: an explicit allowlist of formats the provider's decoders (CoreImage for
// images, AVFoundation for video) support, a part-kind cross-check (an image_url
// part must be an image, a video_url part a video), and a header-only megapixel
// cap for every accepted image format (pixel-bomb defense, mirroring the
// provider's own pre-raster gate). HTML, SVG (scriptable), archives, standalone
// executables, and anything else outside the allowlist is rejected; trailing
// bytes in an otherwise-valid media container are never executed here.

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"image"
	"image/gif"
	"image/jpeg"
	"image/png"
	"math"
	"net/http"
	"strings"
)

// mediaKind is the request-declared kind of a media part: an image_url part
// declares kindImage, a video_url part kindVideo. The sniffed bytes must match.
type mediaKind string

const (
	kindImage mediaKind = "image"
	kindVideo mediaKind = "video"
)

// allowedSniffedTypes maps each sniffed MIME type the coordinator will inline to
// the media kind it satisfies. Deliberately restricted to formats the provider
// can decode: CoreImage handles the image set; AVFoundation decodes MP4/QuickTime
// but NOT WebM/AVI/Matroska — inlining those would burn a fetch + dispatch just
// to 400 at the provider, so they are rejected here with a clear error instead.
// SVG never sniffs as image/* (http.DetectContentType yields text/xml or
// text/html), so scriptable vector content fails the allowlist by construction.
var allowedSniffedTypes = map[string]mediaKind{
	"image/jpeg": kindImage,
	"image/png":  kindImage,
	"image/gif":  kindImage,
	"image/webp": kindImage,
	"image/bmp":  kindImage,

	"video/mp4":       kindVideo,
	"video/quicktime": kindVideo, // custom sniff below; DetectContentType doesn't classify qt brands
}

// fetchedMedia is the result of a successful fetch: validated bytes plus the
// sniffed MIME type used to build the data: URI.
type fetchedMedia struct {
	mime string
	data []byte
}

// sniffMediaType returns the sniffed MIME type and kind for data, or ok=false
// when the bytes are not an allowlisted image/video format. The sniffed type
// (not the response header) is authoritative, so a server claiming image/png
// while serving HTML/SVG/an archive is rejected.
func sniffMediaType(data []byte) (mime string, kind mediaKind, ok bool) {
	ct := http.DetectContentType(data) // e.g. "image/png", "video/mp4", "text/plain; charset=utf-8"
	base := strings.TrimSpace(strings.SplitN(ct, ";", 2)[0])
	if base == "application/octet-stream" {
		// DetectContentType's MP4 matcher only recognizes ftyp brands starting
		// "mp4"; QuickTime files (brand "qt  ") fall through to octet-stream.
		// AVFoundation decodes .mov natively, so classify it ourselves.
		if isQuickTime(data) {
			base = "video/quicktime"
		}
	}
	k, allowed := allowedSniffedTypes[base]
	if !allowed {
		return "", "", false
	}
	return base, k, true
}

// isQuickTime reports whether data starts with an ISO-BMFF ftyp box whose major
// brand is QuickTime ("qt  "). Layout: [4-byte box size]["ftyp"][4-byte major
// brand][...]. Only the major brand is checked — compatible-brand scanning isn't
// needed for the .mov files AVFoundation targets.
func isQuickTime(data []byte) bool {
	return len(data) >= 12 &&
		bytes.Equal(data[4:8], []byte("ftyp")) &&
		bytes.Equal(data[8:12], []byte("qt  "))
}

// validateFetchedMedia enforces the post-download structural policy for one
// media item: allowlisted format, declared-kind match, and the image pixel cap.
// Returns the sniffed MIME type to build the data: URI from.
func (r *Resolver) validateFetchedMedia(declared mediaKind, data []byte) (string, error) {
	mime, kind, ok := sniffMediaType(data)
	if !ok {
		return "", &Error{Status: http.StatusBadRequest, Code: "media_invalid_type",
			Public:   "a media URL did not return a supported image or video format (supported: JPEG, PNG, GIF, WebP, BMP images; MP4/QuickTime video)",
			Internal: fmt.Sprintf("sniffed type %q not in allowlist", http.DetectContentType(data))}
	}
	if kind != declared {
		return "", &Error{Status: http.StatusBadRequest, Code: "media_kind_mismatch",
			Public:   fmt.Sprintf("a %s_url part resolved to %s content; use the matching content-part type", declared, kind),
			Internal: fmt.Sprintf("declared %s_url, sniffed %q", declared, mime)}
	}
	if kind == kindImage {
		if err := r.enforceImagePixelCap(mime, data); err != nil {
			return "", err
		}
	}
	return mime, nil
}

// enforceImagePixelCap rejects decompression/pixel bombs by reading ONLY the
// image header (never a full decode). JPEG/PNG/GIF use stdlib DecodeConfig;
// WebP and BMP use their documented header layouts below. GIF is checked on its
// logical-screen size (per-frame bombs are likewise the provider's aggregate
// caps' job). A header that its own sniffed format cannot parse is rejected
// outright: the provider's decoder would fail on it anyway, so failing fast here
// saves a dispatch.
func (r *Resolver) enforceImagePixelCap(mime string, data []byte) error {
	maxMP := r.cfg.MaxImageMegapixels
	if maxMP <= 0 {
		return nil
	}
	var (
		cfg image.Config
		err error
	)
	switch mime {
	case "image/jpeg":
		cfg, err = jpeg.DecodeConfig(bytes.NewReader(data))
	case "image/png":
		cfg, err = png.DecodeConfig(bytes.NewReader(data))
	case "image/gif":
		cfg, err = gif.DecodeConfig(bytes.NewReader(data))
	case "image/webp":
		cfg.Width, cfg.Height, err = webPDimensions(data)
	case "image/bmp":
		cfg.Width, cfg.Height, err = bmpDimensions(data)
	default:
		err = fmt.Errorf("unsupported image mime %q", mime)
	}
	if err != nil {
		return &Error{Status: http.StatusBadRequest, Code: "media_invalid_type",
			Public:   "a media URL returned an image with an unreadable header",
			Internal: fmt.Sprintf("%s header decode: %v", mime, err)}
	}
	maxPixels := int64(maxMP)
	if maxPixels > math.MaxInt64/1_000_000 {
		maxPixels = math.MaxInt64
	} else {
		maxPixels *= 1_000_000
	}
	width, height := int64(cfg.Width), int64(cfg.Height)
	if width <= 0 || height <= 0 {
		return &Error{Status: http.StatusBadRequest, Code: "media_invalid_type",
			Public:   "a media URL returned an image with invalid dimensions",
			Internal: fmt.Sprintf("%s dimensions %dx%d", mime, cfg.Width, cfg.Height)}
	}
	// Compare by division BEFORE multiplying: OS/2 BMP dimensions are uint32
	// and can otherwise overflow int64 when multiplied (e.g. 0xffffffff² wraps
	// negative and would bypass a naive pixels > maxPixels check).
	if width > maxPixels/height {
		return &Error{Status: http.StatusRequestEntityTooLarge, Code: "media_too_large",
			Public:   fmt.Sprintf("an image exceeds the maximum decoded size of %d megapixels", maxMP),
			Internal: fmt.Sprintf("%s %dx%d exceeds %d MP cap", mime, cfg.Width, cfg.Height, maxMP)}
	}
	return nil
}

// webPDimensions reads the canvas/frame dimensions from each standardized WebP
// bitstream form without decoding pixels: VP8X (extended), VP8L (lossless), and
// VP8 (lossy key frame). See the WebP container specification §2–4.
func webPDimensions(data []byte) (int, int, error) {
	if len(data) < 20 || !bytes.Equal(data[0:4], []byte("RIFF")) || !bytes.Equal(data[8:12], []byte("WEBP")) {
		return 0, 0, fmt.Errorf("invalid WebP RIFF header")
	}
	switch string(data[12:16]) {
	case "VP8X":
		if len(data) < 30 || binary.LittleEndian.Uint32(data[16:20]) < 10 {
			return 0, 0, fmt.Errorf("truncated VP8X header")
		}
		width := 1 + int(data[24]) + int(data[25])<<8 + int(data[26])<<16
		height := 1 + int(data[27]) + int(data[28])<<8 + int(data[29])<<16
		return width, height, nil
	case "VP8L":
		if len(data) < 25 || data[20] != 0x2f {
			return 0, 0, fmt.Errorf("truncated VP8L header")
		}
		width := 1 + int(data[21]) + (int(data[22])&0x3f)<<8
		height := 1 + int(data[22]>>6) + int(data[23])<<2 + (int(data[24])&0x0f)<<10
		return width, height, nil
	case "VP8 ":
		if len(data) < 30 || !bytes.Equal(data[23:26], []byte{0x9d, 0x01, 0x2a}) {
			return 0, 0, fmt.Errorf("invalid VP8 key-frame header")
		}
		width := int(binary.LittleEndian.Uint16(data[26:28]) & 0x3fff)
		height := int(binary.LittleEndian.Uint16(data[28:30]) & 0x3fff)
		if width == 0 || height == 0 {
			return 0, 0, fmt.Errorf("zero-sized VP8 frame")
		}
		return width, height, nil
	default:
		return 0, 0, fmt.Errorf("unsupported WebP chunk %q", data[12:16])
	}
}

// bmpDimensions reads dimensions from the OS/2 BITMAPCOREHEADER (12 bytes) or
// Windows BITMAPINFOHEADER-family DIB headers (>=40 bytes). Negative Windows
// heights indicate top-down row order; their absolute value is the canvas size.
func bmpDimensions(data []byte) (int, int, error) {
	if len(data) < 26 || !bytes.Equal(data[0:2], []byte("BM")) {
		return 0, 0, fmt.Errorf("truncated BMP header")
	}
	dibSize := binary.LittleEndian.Uint32(data[14:18])
	if dibSize == 12 {
		width := int(binary.LittleEndian.Uint16(data[18:20]))
		height := int(binary.LittleEndian.Uint16(data[20:22]))
		if width == 0 || height == 0 {
			return 0, 0, fmt.Errorf("zero-sized BMP canvas")
		}
		return width, height, nil
	}
	// OS/2 2.x defines a 64-byte header plus a legal 16-byte short form. Both
	// store unsigned 32-bit dimensions at the same offsets as Windows headers.
	if dibSize == 16 || dibSize == 64 {
		width64 := uint64(binary.LittleEndian.Uint32(data[18:22]))
		height64 := uint64(binary.LittleEndian.Uint32(data[22:26]))
		maxInt := uint64(^uint(0) >> 1)
		if width64 == 0 || height64 == 0 || width64 > maxInt || height64 > maxInt {
			return 0, 0, fmt.Errorf("invalid OS/2 BMP dimensions %dx%d", width64, height64)
		}
		return int(width64), int(height64), nil
	}
	if dibSize < 40 {
		return 0, 0, fmt.Errorf("unsupported BMP DIB header size %d", dibSize)
	}
	width64 := int64(int32(binary.LittleEndian.Uint32(data[18:22])))
	height64 := int64(int32(binary.LittleEndian.Uint32(data[22:26])))
	if height64 < 0 {
		height64 = -height64
	}
	if width64 <= 0 || height64 <= 0 || width64 > int64(^uint(0)>>1) || height64 > int64(^uint(0)>>1) {
		return 0, 0, fmt.Errorf("invalid BMP dimensions %dx%d", width64, height64)
	}
	return int(width64), int(height64), nil
}

// toDataURI encodes fetched media as a standard base64 data: URI.
func toDataURI(m *fetchedMedia) string {
	return "data:" + m.mime + ";base64," + base64.StdEncoding.EncodeToString(m.data)
}
