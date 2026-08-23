package promptcontract

import (
	"encoding/binary"
	"testing"
)

func FuzzBlockHashBindsIdentityTokensAndBoundaries(f *testing.F) {
	f.Add("contract", "scope", []byte{0, 0, 0, 1}, uint16(4))
	f.Add("", "", []byte{}, uint16(1))
	f.Fuzz(func(t *testing.T, contract, scope string, encoded []byte, rawBlockSize uint16) {
		if len(contract) > 1024 || len(scope) > 1024 || len(encoded) > 4096 {
			t.Skip()
		}
		tokens := make([]uint32, 0, len(encoded)/4)
		for len(encoded) >= 4 {
			tokens = append(tokens, binary.BigEndian.Uint32(encoded[:4]))
			encoded = encoded[4:]
		}
		contractID := []byte(contract)
		scopeID := []byte(scope)
		parent := zeroParent
		baseline, err := BlockHash(contractID, scopeID, parent, 0, tokens)
		if err != nil {
			t.Fatal(err)
		}
		for name, identity := range map[string][32]byte{
			"contract": mustBlockHash(t, mutateBytes(contractID), scopeID, parent, 0, tokens),
			"scope":    mustBlockHash(t, contractID, mutateBytes(scopeID), parent, 0, tokens),
			"parent":   mustBlockHash(t, contractID, scopeID, mutateParent(parent), 0, tokens),
			"index":    mustBlockHash(t, contractID, scopeID, parent, 1, tokens),
			"tokens":   mustBlockHash(t, contractID, scopeID, parent, 0, mutateTokens(tokens)),
		} {
			if identity == baseline {
				t.Fatalf("mutating %s did not change the block hash", name)
			}
		}

		blockSize := int(rawBlockSize%32) + 1
		hashes, err := ChainHashes(contractID, scopeID, tokens, blockSize)
		if err != nil {
			t.Fatal(err)
		}
		if len(hashes) != len(tokens)/blockSize {
			t.Fatalf("chain length = %d, want %d", len(hashes), len(tokens)/blockSize)
		}
		boundary, ok := LastCompleteBoundary(len(tokens), blockSize)
		wantBoundary := 0
		if len(tokens) > 0 {
			wantBoundary = (len(tokens) - 1) / blockSize * blockSize
		}
		if boundary != wantBoundary || ok != (wantBoundary > 0) {
			t.Fatalf("boundary = (%d, %t), want (%d, %t)", boundary, ok, wantBoundary, wantBoundary > 0)
		}
	})
}

func mustBlockHash(
	t *testing.T,
	contractID, scopeID []byte,
	parent [32]byte,
	blockIndex uint32,
	tokens []uint32,
) [32]byte {
	t.Helper()
	hash, err := BlockHash(contractID, scopeID, parent, blockIndex, tokens)
	if err != nil {
		t.Fatal(err)
	}
	return hash
}

func mutateBytes(value []byte) []byte {
	mutated := append([]byte(nil), value...)
	if len(mutated) == 0 {
		return []byte{0}
	}
	mutated[0] ^= 1
	return mutated
}

func mutateParent(parent [32]byte) [32]byte {
	parent[0] ^= 1
	return parent
}

func mutateTokens(tokens []uint32) []uint32 {
	mutated := append([]uint32(nil), tokens...)
	if len(mutated) == 0 {
		return []uint32{0}
	}
	mutated[0] ^= 1
	return mutated
}

func FuzzContractPathValidation(f *testing.F) {
	f.Add("tokenizer.json")
	f.Add("../tokenizer.json")
	f.Add("/absolute")
	f.Fuzz(func(t *testing.T, path string) {
		if len(path) > 4096 {
			t.Skip()
		}
		artifacts := []Artifact{{
			Path: path, Role: "tokenizer", SHA256: "0000000000000000000000000000000000000000000000000000000000000000",
		}}
		_, _ = ContractID(artifacts, CurrentVersions())
	})
}
