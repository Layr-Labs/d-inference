package mdm

// Apple model-identifier → maximum-unified-memory lookup for base rewards.
//
// Why this exists: MDM SecurityInfo and the MDA cert chain attest only the
// device *serial* — never its memory size or model. The only model signal we
// have is AttestationBlob.HardwareModel (e.g. "Mac15,9"), which is self-reported
// and SE-signed (same trust tier as the self-reported MemoryGB heartbeat field).
//
// We therefore use the model identifier ONLY as a downward cap: a machine whose
// self-reported MemoryGB exceeds the maximum its model ever shipped with is
// clamped down to that maximum. We NEVER raise a floor from this table — an
// unknown model returns (0, false) and the caller treats it as "no cap" (it
// trusts the tier-sized correctness probe to be the real verifier instead).
//
// Maxima are keyed on the chip variant baked into each model identifier, since
// the absolute memory ceiling is a property of the SoC (M_/Pro/Max/Ultra):
//
//	M1   8GB / Pro 16 (early Mac mini) / 32 / Max 64 / Ultra 128
//	M2   24GB / Pro 32 / Max 96 / Ultra 192
//	M3   24GB / Pro 36 / Max 128
//	M4   32GB / Pro 64 / Max 128 / (Mac Studio M4 Max 128, M3 Ultra 512)
//
// Sources cross-checked: Apple Tech Specs, EveryMac model-identifier pages,
// AppleDB device selection. When in doubt we pick the LARGEST configuration ever
// offered for that identifier — the cap must never reject an honest machine.

// modelMaxMemoryGB maps an Apple model identifier to the maximum unified memory
// (GB) ever shipped in that identifier. Identifiers absent from this map are
// unknown (return known=false from ModelMaxMemoryGB).
var modelMaxMemoryGB = map[string]int{
	// --- Apple Silicon, M1 family (Mac13,x / MacBookAir10,1 / Macmini9,1) ---
	"MacBookAir10,1": 16,  // MacBook Air (M1, 2020)
	"MacBookPro17,1": 16,  // MacBook Pro 13" (M1, 2020)
	"MacBookPro18,3": 32,  // MacBook Pro 14" (M1 Pro, 2021)
	"MacBookPro18,4": 64,  // MacBook Pro 14" (M1 Max, 2021) — Max → 64
	"MacBookPro18,1": 64,  // MacBook Pro 16" (M1 Pro/Max, 2021)
	"MacBookPro18,2": 64,  // MacBook Pro 16" (M1 Max, 2021)
	"Macmini9,1":     16,  // Mac mini (M1, 2020)
	"iMac21,1":       16,  // iMac 24" (M1, 2021)
	"iMac21,2":       16,  // iMac 24" (M1, 2021)
	"Mac13,1":        64,  // Mac Studio (M1 Max, 2022)
	"Mac13,2":        128, // Mac Studio (M1 Ultra, 2022)

	// --- M2 family (Mac14,x) ---
	"Mac14,2":  24,  // MacBook Air 13" (M2, 2022)
	"Mac14,15": 24,  // MacBook Air 15" (M2, 2023)
	"Mac14,7":  24,  // MacBook Pro 13" (M2, 2022)
	"Mac14,5":  96,  // MacBook Pro 14" (M2 Max, 2023)
	"Mac14,9":  96,  // MacBook Pro 14" (M2 Pro/Max, 2023) — Max → 96
	"Mac14,6":  96,  // MacBook Pro 16" (M2 Max, 2023)
	"Mac14,10": 96,  // MacBook Pro 16" (M2 Pro/Max, 2023) — Max → 96
	"Mac14,3":  24,  // Mac mini (M2, 2023)
	"Mac14,12": 32,  // Mac mini (M2 Pro, 2023)
	"Mac14,13": 192, // Mac Studio (M2 Max/Ultra, 2023) — Ultra → 192
	"Mac14,14": 192, // Mac Studio (M2 Ultra, 2023)
	"Mac14,8":  192, // Mac Pro (M2 Ultra, 2023)

	// --- M3 family (Mac15,x) ---
	"Mac15,12": 24,  // MacBook Air 13" (M3, 2024)
	"Mac15,13": 24,  // MacBook Air 15" (M3, 2024)
	"Mac15,3":  24,  // MacBook Pro 14" (M3, 2023)
	"Mac15,4":  24,  // iMac 24" (M3, 2023)
	"Mac15,5":  24,  // iMac 24" (M3, 2023)
	"Mac15,6":  36,  // MacBook Pro 14" (M3 Pro, 2023)
	"Mac15,8":  128, // MacBook Pro 14" (M3 Max, 2023)
	"Mac15,10": 128, // MacBook Pro 14" (M3 Max, 2023)
	"Mac15,7":  36,  // MacBook Pro 16" (M3 Pro, 2023)
	"Mac15,9":  128, // MacBook Pro 16" (M3 Max, 2023)
	"Mac15,11": 128, // MacBook Pro 16" (M3 Max, 2023)

	// --- M4 family (Mac16,x) ---
	"Mac16,1":  32,  // MacBook Pro 14" (M4, 2024)
	"Mac16,2":  32,  // iMac 24" (M4, 2024)
	"Mac16,3":  32,  // iMac 24" (M4, 2024)
	"Mac16,6":  128, // MacBook Pro 14" (M4 Max, 2024)
	"Mac16,8":  128, // MacBook Pro 14" (M4 Pro/Max, 2024) — Max → 128
	"Mac16,5":  128, // MacBook Pro 16" (M4 Max, 2024)
	"Mac16,7":  128, // MacBook Pro 16" (M4 Pro/Max, 2024) — Max → 128
	"Mac16,10": 32,  // Mac mini (M4, 2024)
	"Mac16,11": 64,  // Mac mini (M4 Pro, 2024)
	"Mac16,12": 32,  // MacBook Air 13" (M4, 2025)
	"Mac16,13": 32,  // MacBook Air 15" (M4, 2025)

	// --- Mac Studio (2025): M4 Max + M3 Ultra ---
	// Mac16,9 is AMBIGUOUS: it covers both the M4 Max Mac Studio (max 128GB) and
	// the M3 Ultra Mac Studio (max 512GB). Since memory is only clamped DOWN and
	// the probe does not yet verify a tier-sized model, capping at 512 would let a
	// 128GB M4 Max self-report 512GB and bank the top $40 floor. We cap
	// conservatively at 128 until the tier-sized correctness probe can confirm a
	// genuine ≥512GB machine (a rare honest M3 Ultra is under-tiered until then).
	"Mac16,9": 128,
}

// ModelMaxMemoryGB returns the maximum unified memory (GB) ever shipped in the
// given Apple model identifier (e.g. "Mac15,9") and whether the model is known.
//
// This is used ONLY as a downward cap on a provider's self-reported memory tier:
// a self-reported MemoryGB above this value is clamped to it; an equal-or-below
// value is accepted as that machine's tier ceiling. It NEVER raises a floor.
//
// Unknown models return (0, false); the caller MUST treat that as "no cap"
// (trust the tier-sized correctness probe) rather than as a zero ceiling — a
// model we have not catalogued must not be silently denied its earned tier.
func ModelMaxMemoryGB(hardwareModel string) (gb int, known bool) {
	gb, known = modelMaxMemoryGB[hardwareModel]
	return gb, known
}
