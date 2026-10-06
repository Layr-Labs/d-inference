package mediawork

import (
	"fmt"
	"math"
)

// resize mirrors MiMoV26MediaGeometry.resize, including ties-to-even and the
// tiny-axis branch. Keeping metadata accounting separate never changes pixels.
func (p *Profile) resize(height, width, minimum, maximum int) (int, int, bool) {
	if p == nil || height <= 0 || width <= 0 || height > 1<<20 || width > 1<<20 {
		return 0, 0, false
	}
	h, w := float64(height), float64(width)
	factor := float64(p.patch * p.merge)
	if math.Min(h, w) < factor {
		scale := factor / math.Min(h, w)
		h, w = math.RoundToEven(h*scale), math.RoundToEven(w*scale)
	} else if math.Max(h, w)/math.Min(h, w) > 200 {
		return 0, 0, false
	}
	pixels := h * w
	if pixels > 1<<53 {
		return 0, 0, false
	}
	rh, rw := math.RoundToEven(h/factor)*factor, math.RoundToEven(w/factor)*factor
	if rh*rw > float64(maximum) {
		beta := math.Sqrt(pixels / float64(maximum))
		rh, rw = math.Floor(h/beta/factor)*factor, math.Floor(w/beta/factor)*factor
	} else if rh*rw < float64(minimum) {
		beta := math.Sqrt(float64(minimum) / pixels)
		rh, rw = math.Ceil(h*beta/factor)*factor, math.Ceil(w*beta/factor)*factor
	}
	if rh <= 0 || rw <= 0 || rh > 1<<30 || rw > 1<<30 || rh*rw > 1<<40 {
		return 0, 0, false
	}
	return int(rh), int(rw), true
}

func (p *Profile) ImageTokens(height, width int) (int, bool) {
	if p == nil {
		return 0, false
	}
	h, w, ok := p.resize(height, width, p.imageMin, p.imageMax)
	if !ok {
		return 0, false
	}
	return h/p.patch*(w/p.patch)/(p.merge*p.merge) + 2, true
}

// VideoTokens uses the native sampler's even frame rounding and real track
// sample count/duration. Timestamp text remains a byte upper estimate; the
// result is deliberately not an exact tokenizer or cache certificate.
func (p *Profile) VideoTokens(height, width, frames int, duration float64) (int, bool) {
	if p == nil || frames < 2 || frames > 10_000_000 || duration <= 0 || math.IsInf(duration, 0) || math.IsNaN(duration) {
		return 0, false
	}
	chosen := min(max(duration*p.fps, float64((p.minFrames+1)/2*2)), float64(p.maxFrames/2*2), float64(frames))
	n := int(math.Floor(chosen/2)) * 2
	if n < 2 {
		return 0, false
	}
	maximum := max(p.videoMin, min(p.videoTotal*p.temporal/n, p.videoMax))
	h, w, ok := p.resize(height, width, p.videoMin, maximum)
	if !ok {
		return 0, false
	}
	groups := (n + p.temporal - 1) / p.temporal
	tokens := groups*(h/p.patch)*(w/p.patch)/(p.merge*p.merge) + 2*groups + 2
	// Every timestamp is at most the final track time. The byte count bounds
	// its tokenization without reading or exporting tokenizer inputs.
	if duration > 1e9 {
		return 0, false
	}
	seconds := int(math.Ceil(duration))
	tokens += groups * len(fmt.Sprintf("%02d:%02d", seconds/60, seconds%60))
	if tokens <= 0 || tokens > 1<<30 {
		return 0, false
	}
	return tokens, true
}
