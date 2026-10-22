package protocol

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"unicode/utf8"
)

const TypeNativePairIntent = "native_pair_intent"

var ErrNativePairIntent = errors.New("invalid configured native pair intent")

// A signed local configuration and consent, never a grant or catalog upsert.
// It consumes the SAME original member-connection sequence as grant responses.
type NativePairIntentMessage struct {
	Type        string `json:"type"`
	Version     uint8  `json:"version"`
	MemberNonce string `json:"member_nonce"`
	Sequence    uint64 `json:"sequence"`
	Payload     string `json:"payload"`
	Signature   string `json:"signature,omitempty"`
}
type NativePairIntent struct {
	ClusterID, ApprovalID string
	PolicySHA256          [32]byte
	MemberIDs             [2]string
	SignerSHA256          [2][32]byte
	Rank                  uint8
	LifetimeSeconds       uint32
}

func (m NativePairIntentMessage) Validate() error {
	raw, e := base64.StdEncoding.DecodeString(m.Payload)
	if m.Type != TypeNativePairIntent || m.Version != 1 || !nativePairHex(m.MemberNonce, 32) || m.Sequence == 0 || e != nil || len(raw) > 1024 || base64.StdEncoding.EncodeToString(raw) != m.Payload {
		return ErrNativePairIntent
	}
	if _, e = DecodeNativePairIntent(raw); e != nil {
		return e
	}
	if m.Signature != "" {
		s, e := base64.StdEncoding.DecodeString(m.Signature)
		if e != nil || len(s) < 8 || len(s) > 72 || base64.StdEncoding.EncodeToString(s) != m.Signature {
			return ErrNativePairIntent
		}
	}
	return nil
}
func (m NativePairIntentMessage) SigningBytes() ([]byte, error) {
	if m.Validate() != nil {
		return nil, ErrNativePairIntent
	}
	b := []byte("darkbloom/coordinator-native-pair/configuration-intent/v1\x00")
	for _, s := range []string{m.Type, m.MemberNonce} {
		b = binary.BigEndian.AppendUint32(b, uint32(len(s)))
		b = append(b, s...)
	}
	b = append(b, m.Version)
	b = binary.BigEndian.AppendUint64(b, m.Sequence)
	raw, _ := base64.StdEncoding.DecodeString(m.Payload)
	b = binary.BigEndian.AppendUint32(b, uint32(len(raw)))
	return append(b, raw...), nil
}
func DecodeNativePairIntentMessage(data []byte) (*NativePairIntentMessage, error) {
	if len(data) == 0 || len(data) > 4096 || bytes.IndexByte(data, 10) >= 0 {
		return nil, ErrNativePairIntent
	}
	d := json.NewDecoder(bytes.NewReader(data))
	tok, e := d.Token()
	if e != nil || tok != json.Delim('{') {
		return nil, ErrNativePairIntent
	}
	seen := map[string]bool{}
	for d.More() {
		k, e := d.Token()
		s, ok := k.(string)
		if e != nil || !ok || seen[s] {
			return nil, ErrNativePairIntent
		}
		seen[s] = true
		switch s {
		case "type", "version", "member_nonce", "sequence", "payload", "signature":
		default:
			return nil, ErrNativePairIntent
		}
		var v json.RawMessage
		if d.Decode(&v) != nil || bytes.Equal(v, []byte("null")) {
			return nil, ErrNativePairIntent
		}
	}
	if tok, e = d.Token(); e != nil || tok != json.Delim('}') {
		return nil, ErrNativePairIntent
	}
	if _, e = d.Token(); e != io.EOF {
		return nil, ErrNativePairIntent
	}
	for _, k := range []string{"type", "version", "member_nonce", "sequence", "payload", "signature"} {
		if !seen[k] {
			return nil, ErrNativePairIntent
		}
	}
	var m NativePairIntentMessage
	if json.Unmarshal(data, &m) != nil || m.Validate() != nil || m.Signature == "" {
		return nil, ErrNativePairIntent
	}
	return &m, nil
}
func intentText(s string) bool {
	if len(s) == 0 || len(s) > 128 || !utf8.ValidString(s) {
		return false
	}
	for _, c := range s {
		if c < 33 || c == 127 {
			return false
		}
	}
	return true
}
func (p NativePairIntent) Canonical() ([]byte, error) {
	if !intentText(p.ClusterID) || !intentText(p.ApprovalID) || p.PolicySHA256 == [32]byte{} || p.Rank > 1 || p.LifetimeSeconds != 300 || p.MemberIDs[0] == p.MemberIDs[1] || p.SignerSHA256[0] == p.SignerSHA256[1] {
		return nil, ErrNativePairIntent
	}
	b := []byte("DBNIC\x01")
	add := func(s string) { b = binary.BigEndian.AppendUint32(b, uint32(len(s))); b = append(b, s...) }
	add(p.ClusterID)
	add(p.ApprovalID)
	b = append(b, p.PolicySHA256[:]...)
	for i, s := range p.MemberIDs {
		if !intentText(s) || p.SignerSHA256[i] == [32]byte{} {
			return nil, ErrNativePairIntent
		}
		add(s)
		b = append(b, p.SignerSHA256[i][:]...)
	}
	b = append(b, p.Rank)
	return binary.BigEndian.AppendUint32(b, p.LifetimeSeconds), nil
}
func DecodeNativePairIntent(b []byte) (NativePairIntent, error) {
	var p NativePairIntent
	original := b
	take := func(n int) []byte {
		if n < 0 || n > len(b) {
			return nil
		}
		v := b[:n]
		b = b[n:]
		return v
	}
	text := func() string {
		n := take(4)
		if n == nil {
			return ""
		}
		count := binary.BigEndian.Uint32(n)
		if count > 128 {
			return ""
		}
		return string(take(int(count)))
	}
	if !bytes.Equal(take(6), []byte("DBNIC\x01")) {
		return p, ErrNativePairIntent
	}
	p.ClusterID = text()
	p.ApprovalID = text()
	copy(p.PolicySHA256[:], take(32))
	for i := range p.MemberIDs {
		p.MemberIDs[i] = text()
		copy(p.SignerSHA256[i][:], take(32))
	}
	rank := take(1)
	seconds := take(4)
	if rank == nil || seconds == nil || len(b) != 0 {
		return p, ErrNativePairIntent
	}
	p.Rank = rank[0]
	p.LifetimeSeconds = binary.BigEndian.Uint32(seconds)
	canonical, e := p.Canonical()
	if e != nil || !bytes.Equal(canonical, original) {
		return NativePairIntent{}, ErrNativePairIntent
	}
	return p, nil
}
