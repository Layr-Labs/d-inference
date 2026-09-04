// Copyright © 2026 Eigen Labs.
//
// `KVHeadroomProbe` parity with the live shared gate (T3-03). The probe
// feeds the post-load guard, the post-bridge guard, the self-restart
// guard and the paged-pool decision; `GlobalKVCacheBudget` is built with the
// operator's `memory_reserve_gb`. Both must measure against the SAME
// effective cap — `min(0.9 × physical, physical − configReserve)` — or a
// model that clears the reserve-blind probe by up to `configReserve −
// 0.1 × physical` (1.6 / 0.8 / 0.4 GiB at 24 / 32 / 36 GB with the 4 GiB
// default) is advertised and then starved by the gate: the loaded-but-
// unserveable black hole the guard exists to prevent. Pure over injected
// counters — no MLX globals.

import Foundation
import Testing

@testable import ProviderCore

private let gib: UInt64 = 1024 * 1024 * 1024
private let activation: UInt64 = 7 * gib / 2  // gpt-oss-20b's measured floor

@Suite("KVHeadroomProbe ↔ live-gate reserve parity")
struct KVHeadroomProbeTests {

    @Test("probe == liveKVHeadroomBytes for every (physical, configReserve) tier")
    func parityTable() {
        for physicalGiB in [24, 32, 36, 64] as [UInt64] {
            for reserveGiB in [0, 4, 8] as [UInt64] {
                let physical = physicalGiB * gib
                let reserve = reserveGiB * gib
                let used = 12 * gib
                let probe = KVHeadroomProbe.measuredLiveKVHeadroomBytes(
                    activationReserveBytes: activation,
                    configReserveBytes: reserve,
                    physicalBytes: physical,
                    mlxUsedBytes: used,
                    systemAvailableBytes: .max)
                let gate = UnifiedMemoryCap.liveKVHeadroomBytes(
                    physicalBytes: physical,
                    mlxUsedBytes: used,
                    systemAvailableBytes: .max,
                    activationReserveBytes: activation,
                    configReserveBytes: reserve)
                #expect(probe == gate, "physical \(physicalGiB) GiB, reserve \(reserveGiB) GiB")
            }
        }
    }

    @Test("with the 4 GiB default the reserve-blind figure over-reports by 1.6 / 0.8 / 0.4 / 0 GiB at 24 / 32 / 36 / 64 GB")
    func reserveBlindOverReport() {
        let expectedDeltaGiB: [UInt64: Double] = [24: 1.6, 32: 0.8, 36: 0.4, 64: 0]
        for (physicalGiB, deltaGiB) in expectedDeltaGiB {
            let physical = physicalGiB * gib
            let used = 12 * gib
            let blind = KVHeadroomProbe.measuredLiveKVHeadroomBytes(
                activationReserveBytes: activation, configReserveBytes: 0,
                physicalBytes: physical, mlxUsedBytes: used, systemAvailableBytes: .max)
            let honest = KVHeadroomProbe.measuredLiveKVHeadroomBytes(
                activationReserveBytes: activation, configReserveBytes: 4 * gib,
                physicalBytes: physical, mlxUsedBytes: used, systemAvailableBytes: .max)
            #expect(blind >= honest)
            let delta = Double(blind - honest) / Double(gib)
            #expect(abs(delta - deltaGiB) < 1e-6, "physical \(physicalGiB) GiB: delta \(delta) GiB")
        }
    }

    @Test("the admit-then-starve band: a 24 GB box that passes reserve-blind refuses at load with the gate's reserve")
    func postLoadGuardRefusesInTheBand() {
        // 24 GiB: cap = 0.9 × 24 = 21.6 GiB; effective cap with the 4 GiB
        // reserve = 20 GiB. Resident 16.6 GiB leaves 1.5 GiB above the
        // activation floor under the blind cap (≥ the 1 GiB minimum, so the
        // guard used to pass) and nothing under the honest one.
        let physical = 24 * gib
        let used = UnifiedMemoryCap.hardCapBytes(physicalBytes: physical) - activation - 3 * gib / 2
        let blind = KVHeadroomProbe.measuredLiveKVHeadroomBytes(
            activationReserveBytes: activation, configReserveBytes: 0,
            physicalBytes: physical, mlxUsedBytes: used, systemAvailableBytes: .max)
        #expect(blind == 3 * gib / 2)
        #expect(KVHeadroomProbe.hasServeableKVHeadroom(
            activationReserveBytes: activation, configReserveBytes: 0,
            physicalBytes: physical, mlxUsedBytes: used, systemAvailableBytes: .max))
        #expect(!KVHeadroomProbe.hasServeableKVHeadroom(
            activationReserveBytes: activation, configReserveBytes: 4 * gib,
            physicalBytes: physical, mlxUsedBytes: used, systemAvailableBytes: .max))
        // The post-bridge verdict takes the same measured figure on both
        // backends: contiguous is the classic guard; paged additionally
        // needs a serveable pool.
        let honest = KVHeadroomProbe.measuredLiveKVHeadroomBytes(
            activationReserveBytes: activation, configReserveBytes: 4 * gib,
            physicalBytes: physical, mlxUsedBytes: used, systemAvailableBytes: .max)
        #expect(honest == 0)
        #expect(!KVHeadroomProbe.postBuildServeable(
            kvBackendKind: .contiguous, pagedPoolBytes: 0,
            activationReserveBytes: activation, configReserveBytes: 4 * gib,
            measuredHeadroomBytes: honest))
        #expect(KVHeadroomProbe.postBuildServeable(
            kvBackendKind: .contiguous, pagedPoolBytes: 0,
            activationReserveBytes: activation, configReserveBytes: 0,
            measuredHeadroomBytes: blind))
        #expect(!KVHeadroomProbe.postBuildServeable(
            kvBackendKind: .paged, pagedPoolBytes: 2 * gib,
            activationReserveBytes: activation, configReserveBytes: 4 * gib,
            measuredHeadroomBytes: honest))
    }

    @Test("≥ 40 GB boxes are unaffected: the fraction reserve already exceeds the default config reserve")
    func largeBoxesUnchanged() {
        for physicalGiB in [40, 48, 64, 128] as [UInt64] {
            let physical = physicalGiB * gib
            let blind = KVHeadroomProbe.measuredLiveKVHeadroomBytes(
                activationReserveBytes: activation, configReserveBytes: 0,
                physicalBytes: physical, mlxUsedBytes: 20 * gib, systemAvailableBytes: .max)
            let honest = KVHeadroomProbe.measuredLiveKVHeadroomBytes(
                activationReserveBytes: activation, configReserveBytes: 4 * gib,
                physicalBytes: physical, mlxUsedBytes: 20 * gib, systemAvailableBytes: .max)
            #expect(blind == honest, "physical \(physicalGiB) GiB")
        }
    }

    @Test("the OS-available clamp still binds below the cap regardless of the config reserve")
    func systemAvailableClampStillBinds() {
        let probe = KVHeadroomProbe.measuredLiveKVHeadroomBytes(
            activationReserveBytes: 0, configReserveBytes: 4 * gib,
            physicalBytes: 64 * gib, mlxUsedBytes: 10 * gib, systemAvailableBytes: 3 * gib)
        #expect(probe == 3 * gib)
    }
}
