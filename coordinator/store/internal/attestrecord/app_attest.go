package attestrecord

import (
	"bytes"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func CloneAppAttestKey(k contracts.AppAttestShadowKey) *contracts.AppAttestShadowKey {
	k.PublicKey = bytes.Clone(k.PublicKey)
	if k.ValidationCategory != nil {
		v := *k.ValidationCategory
		k.ValidationCategory = &v
	}
	return &k
}
