package api

// provider_body_splice.go is the allocation-free fast path behind the
// protocol-0 cache-isolation sizing and sealing (bodyForCacheAttempt and its
// size-only callers, see provider_body_seal.go).
//
// Those helpers used to decode the whole provider body into
// map[string]json.RawMessage and re-encode it — twice per candidate model per
// request, and again per dispatch attempt — just to add one top-level member. For a body the coordinator itself serialized
// (marshalForwardBody: compact, keys sorted, canonical string escaping) the
// re-encode is the identity on every existing member, so the sealed body is
// the input with `"prompt_cache_key":<value>` spliced in at its sorted
// position, and its size is plain arithmetic.
//
// Exactness argument (encoding/json, escapeHTML=false): a RawMessage value is
// re-emitted through compact, which only drops whitespace outside strings;
// object keys are decoded and re-encoded with appendString, then sorted by
// strings.Compare. So the re-encode is byte-identical to a splice iff (1) the
// body carries no insignificant whitespace anywhere, (2) every top-level key
// is escape-free printable ASCII without `"`/`\` (decoded == raw, and
// re-encoding is the identity), and (3) the keys are strictly increasing
// (already sorted, no duplicates to collapse). Anything else — a caller's
// verbatim pretty-printed body, non-ASCII keys, duplicates — takes the
// decode/re-encode path exactly as before.
//
// The scanner is a complete structural validator of the JSON grammar
// encoding/json's scanner accepts (object/array structure, string escapes and
// control bytes, number and literal syntax, nesting bounded well below the
// decoder's limit), so a body it indexes is one the decode path would have
// accepted; it does not check UTF-8 validity, which the decoder does not
// reject either (RawMessage values are copied verbatim).
