package mediafetch

// sniff.go decides what fetched bytes actually ARE — from magic bytes, never the
// spoofable Content-Type header — and enforces the structural safety policy on
// them: an explicit allowlist of formats the provider's decoders (CoreImage for
// images, AVFoundation for video) support, a part-kind cross-check (an image_url
// part must be an image, a video_url part a video), and a header-only megapixel
// cap for stdlib-decodable images (pixel-bomb defense, mirroring the provider's
// own pre-raster gate). HTML, SVG (scriptable), archives, executables, and
// anything else outside the allowlist is rejected.

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"image"
	"image/gif"
	"image/jpeg"
	"image/png"
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
		bytes.HasPrefix(data[8:12], []byte("qt"))
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
// image header (never a full decode) for formats the Go stdlib can parse
// (JPEG/PNG/GIF). WebP/BMP have no stdlib header decoder and rely on the
// provider's own pre-raster pixel cap (the authoritative second layer); GIF is
// checked on its logical-screen size (per-frame bombs are likewise the
// provider's aggregate caps' job). A header that its own sniffed format cannot
// parse is rejected outright: the provider's decoder would fail on it anyway,
// so failing fast here saves a dispatch.
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
	default:
		return nil
	}
	if err != nil {
		return &Error{Status: http.StatusBadRequest, Code: "media_invalid_type",
			Public:   "a media URL returned an image with an unreadable header",
			Internal: fmt.Sprintf("%s header decode: %v", mime, err)}
	}
	pixels := int64(cfg.Width) * int64(cfg.Height)
	if pixels > int64(maxMP)*1_000_000 {
		return &Error{Status: http.StatusRequestEntityTooLarge, Code: "media_too_large",
			Public:   fmt.Sprintf("an image exceeds the maximum decoded size of %d megapixels", maxMP),
			Internal: fmt.Sprintf("%s %dx%d = %d px > %d MP cap", mime, cfg.Width, cfg.Height, pixels, maxMP)}
	}
	return nil
}

// toDataURI encodes fetched media as a standard base64 data: URI.
func toDataURI(m *fetchedMedia) string {
	return "data:" + m.mime + ";base64," + base64.StdEncoding.EncodeToString(m.data)
}
