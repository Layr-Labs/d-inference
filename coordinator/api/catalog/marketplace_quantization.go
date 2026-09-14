package catalog

import (
	"strings"
)

// openRouterValidQuant is the set of quantization strings OpenRouter accepts.
var openRouterValidQuant = map[string]bool{
	"int4": true, "int8": true, "fp4": true, "fp6": true,
	"fp8": true, "fp16": true, "bf16": true, "fp32": true,
}

// quantAliases maps common MLX / HuggingFace quantization spellings onto the
// OpenRouter-accepted vocabulary.
var quantAliases = map[string]string{
	"4bit": "int4", "4-bit": "int4", "q4": "int4", "int4": "int4",
	"8bit": "int8", "8-bit": "int8", "q8": "int8", "int8": "int8",
	"6bit": "fp6", "6-bit": "fp6",
	"3bit": "int4", "3-bit": "int4", // no int3 in OpenRouter; nearest is int4
	"2bit": "int4", "2-bit": "int4", // no int2 in OpenRouter; nearest is int4
	"fp4": "fp4", "fp6": "fp6", "fp8": "fp8",
	"fp16": "fp16", "bf16": "bf16", "fp32": "fp32",
	"float16": "fp16", "bfloat16": "bf16", "float32": "fp32",
}

// mapQuantizationToOpenRouter normalizes an internal quantization label to the
// OpenRouter vocabulary. Returns "" when no confident mapping exists so the
// caller can omit the field.
func mapQuantizationToOpenRouter(q string) string {
	key := strings.ToLower(strings.TrimSpace(q))
	if key == "" {
		return ""
	}
	if mapped, ok := quantAliases[key]; ok {
		return mapped
	}
	if openRouterValidQuant[key] {
		return key
	}
	// Tolerate trailing descriptors like "4bit-gs64" or "mxfp4".
	for alias, mapped := range quantAliases {
		if strings.Contains(key, alias) {
			return mapped
		}
	}
	return ""
}
