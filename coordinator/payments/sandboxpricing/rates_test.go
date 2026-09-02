package sandboxpricing

import (
	"testing"
	"time"
)

const gib = int64(1) << 30

// The economics plan publishes an example price table. Reproducing it exactly
// is the strongest check available: if the implementation and the published
// rate card ever disagree, one of them is wrong and a customer is quoted a
// number nobody agreed to.
func TestHourlyPricesMatchThePublishedRateCard(t *testing.T) {
	cases := []struct {
		name          string
		shape         Shape
		base          int64 // micro-USD per hour
		macOS         int64
		macOSComputer int64
	}{
		// 4 vCPU / 8 GiB: $0.3312 base, $0.4968 macOS, $0.6210 computer
		{"4vcpu-8gib", Shape{4, 8 * gib}, 331_200, 496_800, 621_000},
		// 6 vCPU / 16 GiB: $0.5616, $0.8424, $1.0530
		{"6vcpu-16gib", Shape{6, 16 * gib}, 561_600, 842_400, 1_053_000},
		// 8 vCPU / 32 GiB: $0.9216, $1.3824, $1.7280
		{"8vcpu-32gib", Shape{8, 32 * gib}, 921_600, 1_382_400, 1_728_000},
		// 10 vCPU / 48 GiB: $1.2816, $1.9224, $2.4030
		{"10vcpu-48gib", Shape{10, 48 * gib}, 1_281_600, 1_922_400, 2_403_000},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := HourlyBaseMicroUSD(tc.shape); got != tc.base {
				t.Fatalf("base hourly = %d, want %d", got, tc.base)
			}
			for _, want := range []struct {
				product Product
				total   int64
			}{
				{ProductLinux, tc.base},
				{ProductMacOS, tc.macOS},
				{ProductMacOSComputer, tc.macOSComputer},
			} {
				quote := Price(want.product, tc.shape, time.Hour)
				if got := quote.TotalMicroUSD(); got != want.total {
					t.Errorf("%s hourly total = %d, want %d",
						want.product, got, want.total)
				}
			}
		})
	}
}

// The plan says the premium must remain a separate line item so chip and
// computer-use supply can move independently later.
func TestBaseAndPremiumAreSeparableNotCollapsed(t *testing.T) {
	shape := Shape{4, 8 * gib}

	linux := Price(ProductLinux, shape, time.Hour)
	if linux.PremiumMicroUSD != 0 {
		t.Errorf("linux premium = %d, want 0", linux.PremiumMicroUSD)
	}
	if linux.BaseMicroUSD != 331_200 {
		t.Errorf("linux base = %d, want 331200", linux.BaseMicroUSD)
	}

	mac := Price(ProductMacOS, shape, time.Hour)
	if mac.BaseMicroUSD != linux.BaseMicroUSD {
		t.Errorf("macOS base = %d, want the same base as linux %d",
			mac.BaseMicroUSD, linux.BaseMicroUSD)
	}
	if mac.PremiumMicroUSD != 165_600 {
		t.Errorf("macOS premium = %d, want 165600", mac.PremiumMicroUSD)
	}
	if mac.BaseMicroUSD+mac.PremiumMicroUSD != mac.TotalMicroUSD() {
		t.Error("total must be exactly base plus premium")
	}
}

// The plan is explicit that there is no hidden 24-hour compute floor: a short
// sandbox is charged for what it used.
func TestShortWindowsAreChargedProRataWithNoMinimum(t *testing.T) {
	shape := Shape{4, 8 * gib}

	// A 15-minute macOS window is quoted at most $0.1242 in the plan.
	quarter := Price(ProductMacOS, shape, 15*time.Minute)
	if got := quarter.TotalMicroUSD(); got != 124_200 {
		t.Errorf("15-minute macOS total = %d, want 124200", got)
	}

	// Ninety seconds is ninety seconds, not a minimum block.
	short := Price(ProductMacOS, shape, 90*time.Second)
	if short.TotalMicroUSD() >= quarter.TotalMicroUSD() {
		t.Error("a 90-second window must cost less than a 15-minute one")
	}
	if short.TotalMicroUSD() <= 0 {
		t.Error("a 90-second window must still cost something")
	}
}

func TestRoundingNeverChargesForAPartialSecond(t *testing.T) {
	shape := Shape{4, 8 * gib}
	whole := Price(ProductMacOS, shape, 10*time.Second)
	partial := Price(ProductMacOS, shape, 10*time.Second+900*time.Millisecond)
	if whole.TotalMicroUSD() != partial.TotalMicroUSD() {
		t.Errorf("partial second changed the price: %d vs %d",
			whole.TotalMicroUSD(), partial.TotalMicroUSD())
	}
	if partial.Duration != 10*time.Second {
		t.Errorf("billed duration = %s, want 10s", partial.Duration)
	}
}

func TestNothingIsChargedForNonBillableInput(t *testing.T) {
	shape := Shape{4, 8 * gib}
	for _, tc := range []struct {
		name     string
		product  Product
		shape    Shape
		duration time.Duration
	}{
		{"zero duration", ProductMacOS, shape, 0},
		{"negative duration", ProductMacOS, shape, -time.Hour},
		{"sub-second", ProductMacOS, shape, 500 * time.Millisecond},
		{"no cpu", ProductMacOS, Shape{0, 8 * gib}, time.Hour},
		{"no memory", ProductMacOS, Shape{4, 0}, time.Hour},
		{"unknown product", Product("gpu"), shape, time.Hour},
	} {
		t.Run(tc.name, func(t *testing.T) {
			quote := Price(tc.product, tc.shape, tc.duration)
			if quote.TotalMicroUSD() != 0 {
				t.Errorf("total = %d, want 0", quote.TotalMicroUSD())
			}
		})
	}
}

// An unknown product must never fall through to base pricing: that would sell
// a premium tier at commodity cost.
func TestUnknownProductIsNotPricedAtBase(t *testing.T) {
	quote := Price(Product("macos-v2"), Shape{4, 8 * gib}, time.Hour)
	if quote.TotalMicroUSD() != 0 {
		t.Fatalf("unknown product priced at %d, want 0", quote.TotalMicroUSD())
	}
	if Product("macos-v2").Valid() {
		t.Error("unknown product must not validate")
	}
}

func TestValidProducts(t *testing.T) {
	for _, p := range []Product{ProductLinux, ProductMacOS, ProductMacOSComputer} {
		if !p.Valid() {
			t.Errorf("%s must be valid", p)
		}
	}
	for _, p := range []Product{"", "windows", "MACOS"} {
		if p.Valid() {
			t.Errorf("%q must not be valid", p)
		}
	}
}
