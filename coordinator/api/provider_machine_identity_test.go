package api

import "testing"

func TestProviderMachineIDContract(t *testing.T) {
	const expected = "63ecd36d8a4ecfab1b8ca32e884921afc9bf303a079cefb06362a6c4c2219ac0"
	if got := providerMachineID("SERIAL-9"); got != expected {
		t.Fatalf("providerMachineID = %q, want %q", got, expected)
	}
	if got := providerMachineID(""); got != "" {
		t.Fatalf("empty serial machine id = %q, want empty", got)
	}
}
