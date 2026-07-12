import Testing

@testable import DarkbloomFanCore

@Suite("Fan hardware discovery")
struct FanHardwareTests {
    @Test("chip identity selects explicit M1 through M5 sensor catalogs")
    func sensorCatalogs() {
        #expect(FanChipFamily(brandString: "Apple M1 Max") == .m1)
        #expect(FanChipFamily(brandString: "Apple M2 Ultra") == .m2)
        #expect(FanChipFamily(brandString: "Apple M3 Pro") == .m3)
        #expect(FanChipFamily(brandString: "Apple M4 Max") == .m4)
        #expect(FanChipFamily(brandString: "Apple M5") == .m5)
        #expect(FanChipFamily(brandString: "Apple M10") == .unknown)
        #expect(FanChipFamily(brandString: "Unknown") == .unknown)

        #expect(GPUTemperatureCatalog.keys(for: .m1) == ["Tg05", "Tg0D", "Tg0L", "Tg0T"])
        #expect(GPUTemperatureCatalog.keys(for: .m2) == ["Tg0f", "Tg0j"])
        #expect(GPUTemperatureCatalog.keys(for: .m3).contains("Tf2A"))
        #expect(GPUTemperatureCatalog.keys(for: .m4).contains("Tg1U"))
        #expect(GPUTemperatureCatalog.keys(for: .m5).contains("Tg1g"))
        #expect(GPUTemperatureCatalog.keys(for: .unknown).isEmpty)
    }

    @Test("discovers all required fan keys and uppercase mode keys")
    func uppercaseModeDiscovery() throws {
        let backend = makeFanBackend()
        let inventory = try FanHardwareReader(backend: backend).discover(
            brandString: "Apple M4 Max"
        )

        #expect(inventory.chipFamily == .m4)
        #expect(inventory.fans.count == 2)
        #expect(inventory.fans[0].modeKey == "F0Md")
        #expect(inventory.fans[1].targetKey == "F1Tg")
        #expect(inventory.ftstKey == "Ftst")
        #expect(!inventory.gpuTemperatureKeys.isEmpty)
    }

    @Test("lowercase M5 mode keys are preferred when present")
    func lowercaseModeDiscovery() throws {
        let backend = makeFanBackend(lowercaseModeKeys: true, chipFamily: .m5)
        // If both variants exist, lowercase remains the selected key.
        backend.setUI8("F0Md", 0)
        let inventory = try FanHardwareReader(backend: backend).discover(
            brandString: "Apple M5 Max"
        )
        #expect(inventory.fans[0].modeKey == "F0md")
        #expect(inventory.chipFamily == .m5)
    }

    @Test("fanless machines are represented without inventing controls")
    func fanlessMachine() throws {
        let backend = makeFanBackend(fanCount: 0)
        let inventory = try FanHardwareReader(backend: backend).discover(
            brandString: "Apple M4"
        )
        #expect(inventory.fans.isEmpty)
    }

    @Test("missing per-fan mode key fails capability discovery")
    func missingModeKey() {
        let backend = makeFanBackend(fanCount: 1)
        backend.remove("F0Md")
        #expect(throws: FanHardwareError.missingModeKey(index: 0)) {
            _ = try FanHardwareReader(backend: backend).discover(
                brandString: "Apple M4"
            )
        }
    }

    @Test("only present plausible GPU sensors enter the inventory")
    func filtersGPUKeys() throws {
        let backend = makeFanBackend(chipFamily: .m4)
        backend.remove("Tg0G")
        backend.setFloat("Tg0H", 2)
        let inventory = try FanHardwareReader(backend: backend).discover(
            brandString: "Apple M4 Max"
        )
        #expect(!inventory.gpuTemperatureKeys.contains("Tg0G"))
        #expect(!inventory.gpuTemperatureKeys.contains("Tg0H"))
        #expect(inventory.gpuTemperatureKeys.contains("Tg1U"))
    }

    @Test("sp78 GPU sensors decode while implausible later samples fail safe")
    func fixedPointTemperatureAndFailure() throws {
        let backend = makeFanBackend(chipFamily: .m1)
        backend.setFixed("Tg05", type: "sp78", raw: 0x2d80)
        let reader = FanHardwareReader(backend: backend)
        let inventory = try reader.discover(brandString: "Apple M1 Max")
        let initial = try reader.gpuTemperatures(in: inventory)
        #expect(initial.first(where: { $0.key == "Tg05" })?.celsius == 45.5)

        backend.setFixed("Tg05", type: "sp78", raw: 0x7f00)
        #expect(throws: FanHardwareError.invalidTemperature(key: "Tg05", value: 127)) {
            _ = try reader.gpuTemperatures(in: inventory)
        }
    }

    @Test("snapshots validate limits before a controller can write")
    func invalidLimits() {
        let backend = makeFanBackend(fanCount: 1)
        backend.setFloat("F0Mn", 5_500)
        backend.setFloat("F0Mx", 5_000)
        #expect(throws: FanHardwareError.invalidFanLimits(
            index: 0,
            minimum: 5_500,
            maximum: 5_000
        )) {
            _ = try FanHardwareReader(backend: backend).discover(
                brandString: "Apple M4"
            )
        }
    }

    @Test("manual-mode polling uses limits captured before takeover")
    func cachedLimitsSurviveFirmwareZero() throws {
        let backend = makeFanBackend(fanCount: 1)
        let reader = FanHardwareReader(backend: backend)
        let inventory = try reader.discover(brandString: "Apple M4")
        backend.setFloat("F0Mx", 0)

        let reading = try #require(reader.fanReadings(in: inventory).first)
        #expect(reading.maximumRPM == 5_000)
        #expect(reading.minimumRPM == 1_200)
    }

    @Test("crash-recovery discovery ignores zero live limits and GPU failures")
    func recoveryDiscoveryIsMinimal() throws {
        let backend = makeFanBackend(fanCount: 1)
        backend.setFloat("F0Mx", 0)
        for key in GPUTemperatureCatalog.keys(for: .m4) {
            backend.remove(key)
        }

        let reader = FanHardwareReader(backend: backend)
        let recovery = try reader.discoverForRecovery(brandString: "Apple M4")
        #expect(recovery.fans.count == 1)
        #expect(recovery.gpuTemperatureKeys.isEmpty)
        #expect(recovery.fanLimits.isEmpty)
        #expect(throws: FanHardwareError.self) {
            _ = try reader.discover(brandString: "Apple M4")
        }
    }
}
