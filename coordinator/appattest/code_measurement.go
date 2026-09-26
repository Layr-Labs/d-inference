package appattest

import "github.com/fxamacker/cbor/v2"

// Observed on physical macOS 27 with the 27 SDK and CDhash opt-in. Apple has
// returned type 2 as either the full 32-byte SHA-256 CodeDirectory digest or
// its 20-byte CandidateCDHash prefix. The short value is evidence only until
// uniquely matched to a durable full digest for an approved release. Unknown
// algorithms remain observable but cannot qualify a build.
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
	if algorithm[0] == 2 && len(digest) != 32 && len(digest) != 20 {
		return nil, nil, invalid("code_directory_measurement")
	}
	return digest, &algorithm[0], nil
}

// CodeDirectorySHA256Candidate returns only Apple-signed type-2 measurements.
// The 20-byte variant is a truncated prefix, never a full SHA-256 digest. A
// caller must separately bind it to exactly one durable qualified full digest.
func (k *Key) CodeDirectorySHA256Candidate() []byte {
	if k == nil || k.CodeDirectoryType == nil || *k.CodeDirectoryType != 2 ||
		(len(k.CodeDirectoryHash) != 20 && len(k.CodeDirectoryHash) != 32) {
		return nil
	}
	return k.CodeDirectoryHash
}

// CodeDirectorySHA256 returns only the currently qualified wire format.
func (k *Key) CodeDirectorySHA256() []byte {
	if k == nil || k.CodeDirectoryType == nil || *k.CodeDirectoryType != 2 || len(k.CodeDirectoryHash) != 32 {
		return nil
	}
	return k.CodeDirectoryHash
}
