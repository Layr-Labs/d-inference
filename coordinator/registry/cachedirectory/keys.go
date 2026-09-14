package cachedirectory

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func HMACBytes(key []byte, parts ...[]byte) []byte {
	m := hmac.New(sha256.New, key)
	var n [4]byte
	for _, part := range parts {
		binary.BigEndian.PutUint32(n[:], uint32(len(part)))
		_, _ = m.Write(n[:])
		_, _ = m.Write(part)
	}
	return m.Sum(nil)
}

func OpaqueHMAC(key []byte, parts ...string) string {
	values := make([][]byte, 0, len(parts))
	for _, part := range parts {
		values = append(values, []byte(part))
	}
	return base64.RawURLEncoding.EncodeToString(HMACBytes(key, values...))
}

// cacheBoundaryKey identifies reusable content, independent of which provider
// holds it. Epochs are validated holder metadata: putting one in this key would
// split identical prefixes into separate buckets and bypass the holder bound.
func BoundaryKey(
	routeKey []byte,
	plan Plan,
	anchor protocol.PrefixCacheAnchor,
) string {
	if len(routeKey) == 0 || !plan.Present() ||
		!ValidAnchor(anchor, promptcontract.BlockSize) {
		return ""
	}
	return OpaqueHMAC(
		routeKey,
		"prefix-v4",
		plan.CacheScope,
		plan.ModelAggregateHash,
		plan.PromptContractID,
		strconv.Itoa(anchor.TokenCount),
		anchor.ChainHash,
	)
}
