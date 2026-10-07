package protocol

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
)

const (
	TypeNativePairPrepared         = "native_pair_prepared"
	TypeNativePairHello            = "native_pair_hello"
	TypeNativePairConfirmation     = "native_pair_confirmation"
	TypeNativePairOwnerReleased    = "native_pair_owner_released"
	TypeNativePairCancel           = "native_pair_cancel"
	TypeNativePairPrepare          = "native_pair_prepare"
	TypeNativePairOwnerStart       = "native_pair_owner_start"
	TypeNativePairBinding          = "native_pair_binding"
	TypeNativePairPeerConfirmation = "native_pair_peer_confirmation"
	NativePairFrameLimit           = 64 * 1024
)

var ErrNativePairFrame = errors.New("invalid native pair public frame")

// Public control only. Payload is canonical native start/hello/binding, a
// confirmation MAC, or the exact cleanup observation. Never a traffic secret,
// prompt, activation, native diagnostic tail, or arbitrary worker JSON.
// Sequence belongs to the original member connection, not to a grant.
// Deadlines are absolute coordinator timestamps, never a new request budget.
type NativePairMessage struct {
	Type                  string `json:"type"`
	Version               uint8  `json:"version"`
	MemberNonce           string `json:"member_nonce"`
	Epoch                 string `json:"epoch"`
	Generation            uint64 `json:"generation"`
	Sequence              uint64 `json:"sequence"`
	Payload               string `json:"payload"`
	Signature             string `json:"signature,omitempty"`
	PrepareBeforeUnixNano int64  `json:"prepare_before_unix_nano,omitempty"`
	ExpiresAtUnixNano     int64  `json:"expires_at_unix_nano,omitempty"`
}

func IsNativePairInbound(t string) bool {
	switch t {
	case TypeNativePairPrepared, TypeNativePairHello, TypeNativePairConfirmation, TypeNativePairOwnerReleased, TypeNativePairCancel:
		return true
	}
	return false
}
func IsNativePairOutbound(t string) bool {
	switch t {
	case TypeNativePairPrepare, TypeNativePairOwnerStart, TypeNativePairBinding, TypeNativePairPeerConfirmation, TypeNativePairCancel:
		return true
	}
	return false
}

// Unlike legacy JSON envelopes, this closed security protocol refuses repeated
// and unknown fields before decoding any grant operation. All values are flat.
func DecodeNativePairMessage(data []byte) (*NativePairMessage, error) {
	if len(data) == 0 || len(data) > NativePairFrameLimit || bytes.IndexByte(data, 10) >= 0 {
		return nil, ErrNativePairFrame
	}
	d := json.NewDecoder(bytes.NewReader(data))
	t, e := d.Token()
	if e != nil || t != json.Delim('{') {
		return nil, ErrNativePairFrame
	}
	seen := map[string]bool{}
	for d.More() {
		k, e := d.Token()
		s, ok := k.(string)
		if e != nil || !ok || seen[s] {
			return nil, ErrNativePairFrame
		}
		seen[s] = true
		switch s {
		case "type", "version", "member_nonce", "epoch", "generation", "sequence", "payload", "signature", "prepare_before_unix_nano", "expires_at_unix_nano":
		default:
			return nil, ErrNativePairFrame
		}
		var value json.RawMessage
		if d.Decode(&value) != nil || bytes.Equal(value, []byte("null")) {
			return nil, ErrNativePairFrame
		}
	}
	if t, e = d.Token(); e != nil || t != json.Delim('}') {
		return nil, ErrNativePairFrame
	}
	if _, e = d.Token(); e != io.EOF {
		return nil, ErrNativePairFrame
	}
	for _, k := range []string{"type", "version", "member_nonce", "epoch", "generation", "sequence", "payload"} {
		if !seen[k] {
			return nil, ErrNativePairFrame
		}
	}
	var m NativePairMessage
	if json.Unmarshal(data, &m) != nil || m.Validate() != nil || (seen["signature"] && m.Signature == "") {
		return nil, ErrNativePairFrame
	}
	return &m, nil
}
func (m NativePairMessage) Validate() error {
	if m.Version != 1 || (!IsNativePairInbound(m.Type) && !IsNativePairOutbound(m.Type)) || !nativePairHex(m.MemberNonce, 32) || !nativePairHex(m.Epoch, 16) || m.Generation == 0 || m.Sequence == 0 {
		return ErrNativePairFrame
	}
	p, e := base64.StdEncoding.DecodeString(m.Payload)
	if e != nil || base64.StdEncoding.EncodeToString(p) != m.Payload || len(p) > 32768 {
		return ErrNativePairFrame
	}
	if m.Signature != "" {
		s, e := base64.StdEncoding.DecodeString(m.Signature)
		if e != nil || len(s) < 8 || len(s) > 72 || base64.StdEncoding.EncodeToString(s) != m.Signature {
			return ErrNativePairFrame
		}
	}
	if m.PrepareBeforeUnixNano < 0 || m.ExpiresAtUnixNano < 0 {
		return ErrNativePairFrame
	}
	return nil
}
func nativePairHex(s string, n int) bool {
	b, e := hex.DecodeString(s)
	return e == nil && len(b) == n && hex.EncodeToString(b) == s && !bytes.Equal(b, make([]byte, n))
}
func (m NativePairMessage) PayloadBytes() ([]byte, error) {
	if m.Validate() != nil {
		return nil, ErrNativePairFrame
	}
	return base64.StdEncoding.DecodeString(m.Payload)
}

// SE signs SHA256 of these bytes using the existing P-256 registration key.
// Length framing and a dedicated domain prevent JSON spelling ambiguities and
// cross-message signatures. Signature is deliberately absent from its input.
func (m NativePairMessage) SigningBytes() ([]byte, error) {
	if m.Validate() != nil {
		return nil, ErrNativePairFrame
	}
	b := []byte("darkbloom/coordinator-native-pair/member-message/v1\x00")
	for _, s := range []string{m.Type, m.MemberNonce, m.Epoch} {
		b = binary.BigEndian.AppendUint32(b, uint32(len(s)))
		b = append(b, s...)
	}
	b = append(b, m.Version)
	b = binary.BigEndian.AppendUint64(b, m.Generation)
	b = binary.BigEndian.AppendUint64(b, m.Sequence)
	p, _ := m.PayloadBytes()
	b = binary.BigEndian.AppendUint32(b, uint32(len(p)))
	b = append(b, p...)
	b = binary.BigEndian.AppendUint64(b, uint64(m.PrepareBeforeUnixNano))
	b = binary.BigEndian.AppendUint64(b, uint64(m.ExpiresAtUnixNano))
	return b, nil
}
