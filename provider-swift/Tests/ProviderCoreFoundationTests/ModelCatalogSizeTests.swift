import Testing
@testable import ProviderCoreFoundation

@Suite("Model catalog size")
struct ModelCatalogSizeTests {
    @Test("exact manifest bytes take precedence and clamp negative values")
    func exactBytes() {
        #expect(
            ModelCatalogSize.bytes(
                totalSizeBytes: 42,
                sizeGB: .infinity
            ) == 42
        )
        #expect(
            ModelCatalogSize.bytes(
                totalSizeBytes: -1,
                sizeGB: 10
            ) == 0
        )
    }

    @Test("legacy decimal gigabytes round to bytes")
    func legacyEstimate() {
        #expect(
            ModelCatalogSize.bytes(
                totalSizeBytes: nil,
                sizeGB: 1.25
            ) == 1_250_000_000
        )
    }

    @Test("malformed and oversized legacy values cannot trap")
    func malformedLegacyEstimate() {
        #expect(
            ModelCatalogSize.bytes(
                totalSizeBytes: nil,
                sizeGB: -.infinity
            ) == 0
        )
        #expect(
            ModelCatalogSize.bytes(
                totalSizeBytes: nil,
                sizeGB: .nan
            ) == 0
        )
        #expect(
            ModelCatalogSize.bytes(
                totalSizeBytes: nil,
                sizeGB: .infinity
            ) == Int64.max
        )
        #expect(
            ModelCatalogSize.bytes(
                totalSizeBytes: nil,
                sizeGB: Double.greatestFiniteMagnitude
            ) == Int64.max
        )
    }
}
