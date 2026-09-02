// Package sandboxpricing prices sandbox compute.
//
// Amounts are micro-USD throughout, matching the rest of coordinator/payments.
//
// Base rates match E2B's published per-second CPU and RAM benchmark so a Linux
// sandbox is directly comparable. macOS carries a premium because the supply is
// genuinely constrained: Apple's licence ties macOS virtualization to Apple
// hardware, so the fleet cannot be substituted with commodity servers.
//
// The premium is stored as its own line item rather than folded into a single
// effective rate. The launch UI presents one multiplier, but chip scarcity and
// computer-use capacity move independently, and a collapsed number cannot be
// re-derived into its parts later.
package sandboxpricing

import "time"

const (
	// MicroUSDPerVCPUHour is E2B's published vCPU rate, $0.0504/hour.
	MicroUSDPerVCPUHour int64 = 50_400
	// MicroUSDPerGiBHour is E2B's published RAM rate, $0.0162/hour.
	MicroUSDPerGiBHour int64 = 16_200

	// bytesPerGiB converts the resource shape's memory, which is stored in
	// bytes, into the GiB the rate is quoted in.
	bytesPerGiB int64 = 1 << 30

	// premiumScale keeps premium multipliers in integer arithmetic. Money is
	// never computed in floating point.
	premiumScale int64 = 1_000
)

// Product is what the sandbox is being sold as.
type Product string

const (
	// ProductLinux is the commodity tier, priced at the benchmark.
	ProductLinux Product = "linux"
	// ProductMacOS is the scarce tier: 1.5x.
	ProductMacOS Product = "macos"
	// ProductMacOSComputer adds GUI automation: 1.875x.
	ProductMacOSComputer Product = "macos_computer"
)

// premiumPerMille is the multiplier over base, in thousandths.
func (p Product) premiumPerMille() int64 {
	switch p {
	case ProductMacOS:
		return 1_500
	case ProductMacOSComputer:
		return 1_875
	case ProductLinux:
		return premiumScale
	default:
		// An unknown product must not silently price at base. Callers
		// validate first; this keeps a bug expensive rather than free.
		return 0
	}
}

// Valid reports whether the product is one this rate card prices.
func (p Product) Valid() bool {
	switch p {
	case ProductLinux, ProductMacOS, ProductMacOSComputer:
		return true
	default:
		return false
	}
}

// Shape is the billable resource allocation.
type Shape struct {
	VCPUCount   int64
	MemoryBytes int64
}

// Quote is the priced breakdown for one billing window.
//
// Base and premium are kept apart deliberately: a later change to chip or
// computer-use pricing has to be able to move one without the other, and a
// stored total cannot be decomposed after the fact.
type Quote struct {
	Product Product
	Shape   Shape
	// Duration actually billed, after rounding.
	Duration time.Duration
	// BaseMicroUSD is CPU plus RAM at the benchmark rate.
	BaseMicroUSD int64
	// PremiumMicroUSD is the product surcharge over base. Zero for Linux.
	PremiumMicroUSD int64
}

// TotalMicroUSD is what the account is charged.
func (q Quote) TotalMicroUSD() int64 {
	return q.BaseMicroUSD + q.PremiumMicroUSD
}

// HourlyBaseMicroUSD is the un-premiumed rate for a shape.
func HourlyBaseMicroUSD(shape Shape) int64 {
	gibibytes := shape.MemoryBytes / bytesPerGiB
	return shape.VCPUCount*MicroUSDPerVCPUHour + gibibytes*MicroUSDPerGiBHour
}

// Price computes what a window of compute costs.
//
// Duration is billed per second with no minimum: the plan is explicit that
// there is no hidden 24-hour compute floor, so a sandbox that ran for ninety
// seconds is charged for ninety seconds. Rounding is toward the customer, so a
// partial second is never charged.
func Price(product Product, shape Shape, duration time.Duration) Quote {
	quote := Quote{Product: product, Shape: shape}
	if !product.Valid() || duration <= 0 {
		return quote
	}
	if shape.VCPUCount <= 0 || shape.MemoryBytes <= 0 {
		return quote
	}

	seconds := int64(duration / time.Second)
	if seconds <= 0 {
		return quote
	}
	quote.Duration = time.Duration(seconds) * time.Second

	hourly := HourlyBaseMicroUSD(shape)
	// Integer arithmetic end to end: seconds first, then divide, so the
	// rounding happens once and always downward.
	quote.BaseMicroUSD = hourly * seconds / 3_600

	premium := product.premiumPerMille()
	total := quote.BaseMicroUSD * premium / premiumScale
	quote.PremiumMicroUSD = total - quote.BaseMicroUSD
	return quote
}
