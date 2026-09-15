package appattest

import "github.com/fxamacker/cbor/v2"

// Observed on physical macOS 27 with the 27 SDK and CDhash opt-in. Type 2
// contains the full SHA-256 CodeDirectory digest, matching codesign's
// CandidateCDHashFull, not its truncated 20-byte CDHash. Unknown algorithms
// remain observable but cannot qualify a build. Raw signed evidence is retained.
func codeDirectoryMeasurement(extensions map[string]cbor.RawMessage) ([]byte, *uint8, error) {
	hash, hasHash := extensions["apple_cd_hash_hash_01"]
	typeValue, hasType := extensions["apple_cd_hash_type_01"]
	if !hasHash && !hasType {
		return nil, nil, nil
	}
	var digest, algorithm []byte
	if !hasHash || !hasType || decoder.Unmarshal(hash, &digest) != nil || decoder.Unmarshal(typeValue, &algorithm) != nil || len(algorithm) != 1 || len(digest) == 0 || len(digest) > 64 {
		return nil, nil, invalid("code_directory_measurement")
	}
	if algorithm[0] == 2 && len(digest) != 32 {
		return nil, nil, invalid("code_directory_measurement")
	}
	return digest, &algorithm[0], nil
}

// CodeDirectorySHA256 returns only the currently qualified wire format.
func (k *Key) CodeDirectorySHA256() []byte {
	if k == nil || k.CodeDirectoryType == nil || *k.CodeDirectoryType != 2 || len(k.CodeDirectoryHash) != 32 {
		return nil
	}
	return k.CodeDirectoryHash
}
