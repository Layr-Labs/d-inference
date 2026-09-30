package promptcontract

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

var (
	blockHashDomain = []byte("darkbloom.prefix-block-chain.v1")
	zeroParent      [sha256.Size]byte

	ErrIdentityTooLarge = errors.New("block-hash identity exceeds uint32 length")
)

func BlockHash(contractID, scopeID []byte, parent [sha256.Size]byte, blockIndex uint32, tokens []uint32) ([sha256.Size]byte, error) {
	if uint64(len(contractID)) > uint64(^uint32(0)) || uint64(len(scopeID)) > uint64(^uint32(0)) {
		return [sha256.Size]byte{}, ErrIdentityTooLarge
	}
	encoded := make([]byte, 0, len(blockHashDomain)+len(contractID)+len(scopeID)+len(tokens)*4+44)
	encoded = append(encoded, blockHashDomain...)
	encoded, _ = appendField(encoded, contractID)
	encoded, _ = appendField(encoded, scopeID)
	encoded = append(encoded, parent[:]...)
	encoded = binary.BigEndian.AppendUint32(encoded, blockIndex)
	for _, token := range tokens {
		encoded = binary.BigEndian.AppendUint32(encoded, token)
	}
	return sha256.Sum256(encoded), nil
}

func LastCompleteBoundary(tokenCount, blockSize int) (int, bool) {
	if tokenCount <= 0 || blockSize <= 0 {
		return 0, false
	}
	boundary := (tokenCount - 1) / blockSize * blockSize
	return boundary, boundary > 0
}
