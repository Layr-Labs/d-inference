package protocol

import "strings"

// Hand-written decoder for the inference_response_chunk frame — the one
// provider→coordinator message that arrives once per streamed token (~117K/s
// at fleet peak). encoding/json spent ~65% of the per-chunk relay CPU on this
// frame; the scanner below decodes the production wire shape with one byte
// walk and two allocations.
//
// It follows type_scan.go's rule: never complete, only never wrong. The fast
// path accepts exactly the shapes it can decode identically to encoding/json —
// the four known top-level keys (type, request_id, data, encrypted_data), the
// two known payload keys, plain printable-ASCII strings with no escapes, and
// null/object for the payload. Anything else (unknown or case-variant keys,
// duplicates, escapes, non-ASCII bytes, numbers, trailing bytes, malformed
// input) reports ok=false and the caller falls back to the generic decode.
// The Swift provider emits keys sorted (JSONEncoder .sortedKeys), so "type" is
// the LAST top-level key on the wire; the scanner reads every key in one pass
// rather than looking for "type" first.
//
// TestScanChunkFrameStructShapeGuard pins the field sets the scanner knows
// about: adding a JSON field to InferenceResponseChunkMessage or
// EncryptedPayload without teaching the scanner would otherwise silently push
// every chunk back onto the slow path.

// chunkFrame co-allocates the message with its payload so a decoded frame is
// one struct allocation plus one string allocation (see buildChunkFrame).
type chunkFrame struct {
	msg InferenceResponseChunkMessage
	enc EncryptedPayload
}

// scanChunkFrame decodes data as an inference_response_chunk frame. ok is
// false when the frame is not a chunk or is any shape the scanner is not
// certain about; callers must then use the generic decode. When ok is true
// the result equals what json.Unmarshal into InferenceResponseChunkMessage
// would produce (FuzzChunkFrameDecode holds this against encoding/json).
func scanChunkFrame(data []byte) (*InferenceResponseChunkMessage, bool) {
	var (
		requestID, chunkData, ephemeral, ciphertext []byte
		seenType, seenRequestID, seenData, seenEnc  bool
		encObject                                   bool // encrypted_data was an object (non-nil payload)
	)
	i := skipJSONWhitespace(data, 0)
	if i >= len(data) || data[i] != '{' {
		return nil, false
	}
	i = skipJSONWhitespace(data, i+1)
	if i < len(data) && data[i] == '}' {
		return nil, false // no "type": not a chunk frame
	}
	for {
		key, next, ok := scanASCIIJSONString(data, i)
		if !ok {
			return nil, false
		}
		i = skipJSONWhitespace(data, next)
		if i >= len(data) || data[i] != ':' {
			return nil, false
		}
		i = skipJSONWhitespace(data, i+1)
		switch string(key) {
		case "type":
			if seenType {
				return nil, false
			}
			seenType = true
			v, vNext, vOK := scanASCIIJSONString(data, i)
			if !vOK || string(v) != TypeInferenceResponseChunk {
				return nil, false
			}
			i = vNext
		case "request_id":
			if seenRequestID {
				return nil, false
			}
			seenRequestID = true
			requestID, i, ok = scanASCIIJSONString(data, i)
			if !ok {
				return nil, false
			}
		case "data":
			if seenData {
				return nil, false
			}
			seenData = true
			chunkData, i, ok = scanASCIIJSONString(data, i)
			if !ok {
				return nil, false
			}
		case "encrypted_data":
			if seenEnc {
				return nil, false
			}
			seenEnc = true
			if i < len(data) && data[i] == '{' {
				ephemeral, ciphertext, i, ok = scanChunkEncryptedPayload(data, i)
				encObject = true
			} else {
				i, ok = scanJSONNull(data, i)
			}
			if !ok {
				return nil, false
			}
		default:
			// Unknown key, or a case variant of a known one that encoding/json
			// would still match: defer to the generic decode.
			return nil, false
		}
		i = skipJSONWhitespace(data, i)
		if i >= len(data) {
			return nil, false
		}
		switch data[i] {
		case ',':
			i = skipJSONWhitespace(data, i+1)
		case '}':
			if skipJSONWhitespace(data, i+1) != len(data) {
				return nil, false // trailing bytes: encoding/json rejects the document
			}
			if !seenType {
				return nil, false
			}
			return buildChunkFrame(requestID, chunkData, ephemeral, ciphertext, encObject), true
		default:
			return nil, false
		}
	}
}

// scanChunkEncryptedPayload scans the encrypted_data object starting at the
// '{' at data[i]. It accepts exactly the two known keys as plain ASCII strings.
func scanChunkEncryptedPayload(data []byte, i int) (ephemeral, ciphertext []byte, next int, ok bool) {
	i = skipJSONWhitespace(data, i+1)
	if i < len(data) && data[i] == '}' {
		return nil, nil, i + 1, true // {} decodes to a zero, non-nil payload
	}
	var seenEphemeral, seenCiphertext bool
	for {
		key, keyNext, keyOK := scanASCIIJSONString(data, i)
		if !keyOK {
			return nil, nil, 0, false
		}
		i = skipJSONWhitespace(data, keyNext)
		if i >= len(data) || data[i] != ':' {
			return nil, nil, 0, false
		}
		i = skipJSONWhitespace(data, i+1)
		switch string(key) {
		case "ephemeral_public_key":
			if seenEphemeral {
				return nil, nil, 0, false
			}
			seenEphemeral = true
			ephemeral, i, keyOK = scanASCIIJSONString(data, i)
		case "ciphertext":
			if seenCiphertext {
				return nil, nil, 0, false
			}
			seenCiphertext = true
			ciphertext, i, keyOK = scanASCIIJSONString(data, i)
		default:
			return nil, nil, 0, false
		}
		if !keyOK {
			return nil, nil, 0, false
		}
		i = skipJSONWhitespace(data, i)
		if i >= len(data) {
			return nil, nil, 0, false
		}
		switch data[i] {
		case ',':
			i = skipJSONWhitespace(data, i+1)
		case '}':
			return ephemeral, ciphertext, i + 1, true
		default:
			return nil, nil, 0, false
		}
	}
}

// scanJSONNull accepts exactly the literal null at data[i] followed by a
// structural byte or whitespace, returning the index after it.
func scanJSONNull(data []byte, i int) (next int, ok bool) {
	if len(data)-i < 4 || string(data[i:i+4]) != "null" {
		return 0, false
	}
	next = i + 4
	if next < len(data) {
		switch data[next] {
		case ',', '}', ' ', '\t', '\n', '\r':
		default:
			return 0, false
		}
	}
	return next, true
}

// scanASCIIJSONString scans a JSON string at data[i] whose content is plain
// printable ASCII (0x20..0x7E) with no escape sequences, so its raw bytes ARE
// its decoded value. Anything else (escapes, control bytes, non-ASCII — which
// encoding/json would unescape or coerce) bails.
func scanASCIIJSONString(data []byte, i int) (s []byte, next int, ok bool) {
	if i >= len(data) || data[i] != '"' {
		return nil, 0, false
	}
	i++
	start := i
	for i < len(data) {
		c := data[i]
		if c == '"' {
			return data[start:i], i + 1, true
		}
		if c == '\\' || c < 0x20 || c >= 0x7f {
			return nil, 0, false
		}
		i++
	}
	return nil, 0, false
}

// buildChunkFrame copies the scanned fields out of the frame buffer into one
// shared string allocation (the four values live and die together with the
// chunk) and one struct allocation for message + payload.
func buildChunkFrame(requestID, chunkData, ephemeral, ciphertext []byte, encObject bool) *InferenceResponseChunkMessage {
	var sb strings.Builder
	sb.Grow(len(requestID) + len(chunkData) + len(ephemeral) + len(ciphertext))
	sb.Write(requestID)
	sb.Write(chunkData)
	sb.Write(ephemeral)
	sb.Write(ciphertext)
	s := sb.String()

	f := &chunkFrame{}
	f.msg.Type = TypeInferenceResponseChunk
	off := 0
	f.msg.RequestID = s[off : off+len(requestID)]
	off += len(requestID)
	f.msg.Data = s[off : off+len(chunkData)]
	off += len(chunkData)
	if encObject {
		f.enc.EphemeralPublicKey = s[off : off+len(ephemeral)]
		off += len(ephemeral)
		f.enc.Ciphertext = s[off : off+len(ciphertext)]
		f.msg.EncryptedData = &f.enc
	}
	return &f.msg
}
