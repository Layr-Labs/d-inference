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
	ErrBlockIndex       = errors.New("block-hash block index exceeds uint32")
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

func ChainHashes(contractID, scopeID []byte, tokens []uint32, blockSize int) ([][sha256.Size]byte, error) {
	if blockSize <= 0 {
		return nil, nil
	}
	hashes := make([][sha256.Size]byte, 0, len(tokens)/blockSize)
	parent := zeroParent
	for start := 0; start+blockSize <= len(tokens); start += blockSize {
		index := start / blockSize
		if uint64(index) > uint64(^uint32(0)) {
			return nil, ErrBlockIndex
		}
		hash, err := BlockHash(contractID, scopeID, parent, uint32(index), tokens[start:start+blockSize])
		if err != nil {
			return nil, err
		}
		hashes = append(hashes, hash)
		parent = hash
	}
	return hashes, nil
}

func LastCompleteBoundary(tokenCount, blockSize int) (int, bool) {
	if tokenCount <= 0 || blockSize <= 0 {
		return 0, false
	}
	boundary := (tokenCount - 1) / blockSize * blockSize
	return boundary, boundary > 0
}
