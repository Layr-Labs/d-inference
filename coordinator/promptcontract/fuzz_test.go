package promptcontract

import (
	"encoding/binary"
	"testing"
)

func FuzzBlockHashDeterministic(f *testing.F) {
	f.Add("contract", "scope", []byte{0, 0, 0, 1})
	f.Add("", "", []byte{})
	f.Fuzz(func(t *testing.T, contract, scope string, encoded []byte) {
		if len(contract) > 1024 || len(scope) > 1024 || len(encoded) > 4096 {
			t.Skip()
		}
		tokens := make([]uint32, 0, len(encoded)/4)
		for len(encoded) >= 4 {
			tokens = append(tokens, binary.BigEndian.Uint32(encoded[:4]))
			encoded = encoded[4:]
		}
		first, err := BlockHash([]byte(contract), []byte(scope), zeroParent, 0, tokens)
		if err != nil {
			t.Fatal(err)
		}
		second, err := BlockHash([]byte(contract), []byte(scope), zeroParent, 0, tokens)
		if err != nil {
			t.Fatal(err)
		}
		if first != second {
			t.Fatal("block hash is nondeterministic")
		}
	})
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
