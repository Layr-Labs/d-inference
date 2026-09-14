package throughput

import "strings"

// Bytes-per-parameter for common quantizations. Decode reads each touched weight
// once per token, so this converts an active-param count into bytes/token.
const (
	// BytesPerParam4Bit is 4-bit group quantization: 4 bits of payload plus a
	// per-group scale (a 16-bit scale over a group of 64 ≈ +0.25 bit, plus a
	// zero-point) ⇒ ~4.5 bits ⇒ 0.5625 bytes/param. This is the midpoint of the
	// 0.50–0.60 range used in the bandwidth analysis.
	BytesPerParam4Bit = 0.5625
	// BytesPerParam8Bit is 8-bit group quantization (~8.5 bits ⇒ ~1.0625 B/param).
	BytesPerParam8Bit = 1.0625
	// BytesPerParamBF16 is half precision (2 bytes/param).
	BytesPerParamBF16 = 2.0
)

// ModelDecodeClass describes the decode-bandwidth class of a model: the number
// of parameters actually read per token (the "active" params — for an MoE this
// is the shared trunk plus the routed top-K experts, which is ≪ total) and the
// bytes read per parameter (set by the served quantization).
type ModelDecodeClass struct {
	// ActiveParams is the number of weights streamed per decoded token.
	ActiveParams float64
	// BytesPerParam is the per-parameter byte cost of the served quantization.
	// Zero means "infer from the model id" (see BytesPerParamForModelID).
	BytesPerParam float64
}

// modelDecodeClasses maps a model id to its decode class. Extend this table as
// models are added — a model absent from the table is simply not evaluated; the
// detector never guesses an active-param count it does not know (which keeps it
// free of false positives on unknown models).
//
// active-param counts:
//   - gpt-oss-20b:          ~3.6B active (pure sparse MoE, top-4 of 128 experts)
//   - gemma-4-26b-qat-4bit: ~4.0B active (sparse experts + an always-on dense FFN)
var modelDecodeClasses = map[string]ModelDecodeClass{
	"gpt-oss-20b":          {ActiveParams: 3.6e9, BytesPerParam: BytesPerParam4Bit},
	"gemma-4-26b-qat-4bit": {ActiveParams: 4.0e9, BytesPerParam: BytesPerParam4Bit},
}

// ExpectedDecodeTPS returns the bandwidth-bound single-stream decode throughput
// (tokens/sec) for a model that reads activeParams weights at bytesPerParam from
// memory with bandwidthGBps peak bandwidth sustained at efficiency:
//
//	expected ≈ bandwidth_GBps × efficiency / (active_params × bytes_per_param)
//
// Returns 0 if any input is non-positive.
func ExpectedDecodeTPS(activeParams, bytesPerParam, bandwidthGBps, efficiency float64) float64 {
	if activeParams <= 0 || bytesPerParam <= 0 || bandwidthGBps <= 0 || efficiency <= 0 {
		return 0
	}
	readGBPerToken := activeParams * bytesPerParam / 1e9 // bytes → GB
	if readGBPerToken <= 0 {
		return 0
	}
	return bandwidthGBps * efficiency / readGBPerToken
}

// LookupModelDecodeClass resolves a model id to its decode class. It tries an
// exact match, then a case-insensitive match, so registry/catalog id casing
// differences do not matter. When the class's BytesPerParam is unset it is
// inferred from quantization hints in the id. ok is false for unknown models.
func (p Policy) LookupModelDecodeClass(model string) (ModelDecodeClass, bool) {
	if c, ok := p.Models[model]; ok {
		return resolveBytesPerParam(model, c), true
	}
	lower := strings.ToLower(strings.TrimSpace(model))
	for id, c := range p.Models {
		if strings.ToLower(id) == lower {
			return resolveBytesPerParam(model, c), true
		}
	}
	return ModelDecodeClass{}, false
}

func resolveBytesPerParam(model string, c ModelDecodeClass) ModelDecodeClass {
	if c.BytesPerParam <= 0 {
		c.BytesPerParam = BytesPerParamForModelID(model)
	}
	return c
}

// BytesPerParamForModelID infers the per-parameter byte cost from quantization
// hints in a model id, defaulting to bf16 when none are present.
func BytesPerParamForModelID(model string) float64 {
	m := strings.ToLower(model)
	switch {
	case containsAny(m, "4bit", "4-bit", "q4", "int4", "qat-4", "mxfp4", "nf4"):
		return BytesPerParam4Bit
	case containsAny(m, "8bit", "8-bit", "q8", "int8"):
		return BytesPerParam8Bit
	default:
		return BytesPerParamBF16
	}
}

func containsAny(s string, subs ...string) bool {
	for _, sub := range subs {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}
