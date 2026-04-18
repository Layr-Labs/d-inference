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

	fmt.Fprintf(os.Stdout, "Attestation from: %s (%s)\n", result.ChipName, result.HardwareModel)
	fmt.Fprintf(os.Stdout, "Secure Enclave: %v | SIP: %v | Secure Boot: %v\n",
		result.SecureEnclaveAvailable, result.SIPEnabled, result.SecureBootEnabled)

	if result.Valid {
		fmt.Fprintln(os.Stdout, "\n✓ CROSS-LANGUAGE VERIFICATION PASSED")
		fmt.Fprintln(os.Stdout, "  Swift Secure Enclave P-256 signature verified by Go coordinator")
	} else {
		fmt.Fprintf(os.Stdout, "\n✗ VERIFICATION FAILED: %s\n", result.Error)
		os.Exit(1)
	}
}
