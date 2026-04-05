package main

import (
	"fmt"
	"os"

	"github.com/eigeninference/coordinator/internal/attestation"
)

func main() {
	data, err := os.ReadFile("/tmp/eigeninference_attestation.json")
	if err != nil {
		fmt.Fprintf(os.Stderr, "read: %v\n", err)
		os.Exit(1)
	}

	result, err := attestation.VerifyJSON(data)
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Attestation from: %s (%s)\n", result.ChipName, result.HardwareModel)
	fmt.Printf("Secure Enclave: %v | SIP: %v | Secure Boot: %v\n",
		result.SecureEnclaveAvailable, result.SIPEnabled, result.SecureBootEnabled)

	if result.Valid {
		fmt.Println("\n✓ CROSS-LANGUAGE VERIFICATION PASSED")
		fmt.Println("  Swift Secure Enclave P-256 signature verified by Go coordinator")
	} else {
		fmt.Printf("\n✗ VERIFICATION FAILED: %s\n", result.Error)
		os.Exit(1)
	}
}
