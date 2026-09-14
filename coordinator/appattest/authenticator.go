package appattest

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"github.com/fxamacker/cbor/v2"
)

type authenticator struct {
	counter                         uint32
	aaguid, credentialID, publicKey []byte
	version                         string
	category                        *uint32
}

func (v *Verifier) authData(data []byte, attest bool) (*authenticator, error) {
	if len(data) < 37 {
		return nil, invalid("authenticator_data")
	}
	rp := sha256.Sum256([]byte(v.policy.AppID))
	if v.policy.AppID == "" || !bytes.Equal(data[:32], rp[:]) {
		return nil, invalid("app_identity")
	}
	if (data[32]&0x40 != 0) != attest {
		return nil, invalid("authenticator_flags")
	}
	a := &authenticator{counter: binary.BigEndian.Uint32(data[33:37])}
	tail := data[37:]
	if attest {
		if len(tail) < 50 || binary.BigEndian.Uint16(tail[16:18]) != 32 {
			return nil, invalid("credential")
		}
		a.aaguid, a.credentialID = tail[:16], tail[18:50]
		var cose map[int]cbor.RawMessage
		var err error
		tail, err = decoder.UnmarshalFirst(tail[50:], &cose)
		if err != nil || len(cose) != 5 {
			return nil, invalid("credential_key")
		}
		var kty, alg, curve int
		var x, y []byte
		if decoder.Unmarshal(cose[1], &kty) != nil || decoder.Unmarshal(cose[3], &alg) != nil || decoder.Unmarshal(cose[-1], &curve) != nil || decoder.Unmarshal(cose[-2], &x) != nil || decoder.Unmarshal(cose[-3], &y) != nil || kty != 2 || alg != -7 || curve != 1 || len(x) != 32 || len(y) != 32 {
			return nil, invalid("credential_key")
		}
		a.publicKey = append(append([]byte{4}, x...), y...)
	}
	if data[32]&0x80 == 0 {
		if len(tail) != 0 {
			return nil, invalid("authenticator_trailing_data")
		}
		return a, nil
	}
	var extensions map[string]cbor.RawMessage
	if len(tail) == 0 || decoder.Unmarshal(tail, &extensions) != nil || extensions == nil {
		return nil, invalid("extensions")
	}
	if raw, ok := extensions["apple_bundle_version_01"]; ok {
		if decoder.Unmarshal(raw, &a.version) != nil || len(a.version) > 128 {
			return nil, invalid("bundle_version")
		}
	}
	if raw, ok := extensions["apple_validation_category_01"]; ok {
		category, err := validationCategory(raw)
		if err != nil {
			return nil, err
		}
		a.category = &category
	}
	return a, nil
}

func validationCategory(raw cbor.RawMessage) (uint32, error) {
	if len(raw) != 0 {
		switch raw[0] >> 5 {
		case 0: // The validation article describes a UInt32.
			var category uint32
			if decoder.Unmarshal(raw, &category) == nil {
				return category, nil
			}
		case 2: // Apple's worked example encodes four little-endian bytes.
			var encoded []byte
			if decoder.Unmarshal(raw, &encoded) == nil && len(encoded) == 4 {
				return binary.LittleEndian.Uint32(encoded), nil
			}
		}
	}
	return 0, invalid("validation_category")
}
