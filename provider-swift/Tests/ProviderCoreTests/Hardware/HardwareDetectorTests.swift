import Testing

@testable import ProviderCore

@Suite("New Mac chip detection")
struct HardwareDetectorTests {
    @Test func m5DesktopVariants() {
        #expect(parseChipIdentity("Apple M5 Pro") == (.m5, .pro))
        #expect(parseChipIdentity("Apple M5 Max") == (.m5, .max))
        #expect(parseChipIdentity("Apple M5 Ultra") == (.m5, .ultra))
        #expect(lookupBandwidth(family: .m5, tier: .ultra, gpuCores: 64) == 1200)
        #expect(lookupBandwidth(family: .m5, tier: .ultra, gpuCores: 80) == 1200)
    }

    @Test func m6MiniUsesConservativeProfile() {
        #expect(parseChipIdentity("Apple M6") == (.m6, .base))
        #expect(lookupBandwidth(family: .m6, tier: .base, gpuCores: 12) == 153)
        #expect(peakFp16Flops(family: .m6, tier: .base, gpuCores: 12) == 0)
    }
}
