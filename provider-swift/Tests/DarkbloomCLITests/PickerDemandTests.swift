import Foundation
import Testing
import ProviderCore

@testable import darkbloom

/// Start picker demand ranking: signal, tiers, labels, ordering, the nil-demand
/// fallback, and a replay of recorded 2026-09-28T14:00Z `/v1/models/capacity`
/// and `/v1/pricing` responses.
@Suite("Start picker demand ranking (StartCommand+PickerDemand)", .serialized)
struct PickerDemandTests {

    // MARK: - Fixtures: recorded 2026-09-28T14:00Z /v1/models/capacity + /v1/pricing (trimmed)

    private static let fixtureCapacityJSON: Data = """
        {
         "models": [
          {
           "id": "EigenLabs/Qwen3.8-27B-4bit-mtp",
           "active_requests": 30,
           "running_providers": 10,
           "warm_providers": 80,
           "cold_providers": 29,
           "queued_requests": 0
          },
          {
           "id": "Qwen3.5-9B",
           "active_requests": 52,
           "running_providers": 36,
           "warm_providers": 125,
           "cold_providers": 75,
           "queued_requests": 0
          },
          {
           "id": "gpt-oss-20b",
           "active_requests": 209,
           "running_providers": 116,
           "warm_providers": 359,
           "cold_providers": 185,
           "queued_requests": 0
          },
          {
           "id": "nvidia-nemotron-3.5-lightning",
           "active_requests": 25,
           "running_providers": 21,
           "warm_providers": 137,
           "cold_providers": 28,
           "queued_requests": 0
          },
          {
           "id": "qwen3.6-35b-a3b-vl-mtp-mxfp8",
           "active_requests": 10,
           "running_providers": 6,
           "warm_providers": 238,
           "cold_providers": 407,
           "queued_requests": 0
          },
          {
           "id": "gemma-4-26b-8bit",
           "active_requests": 0,
           "running_providers": 0,
           "warm_providers": 2,
           "cold_providers": 41,
           "queued_requests": 0
          },
          {
           "id": "ternary-bonsai-2-27b",
           "active_requests": 1,
           "running_providers": 0,
           "warm_providers": 38,
           "cold_providers": 146,
           "queued_requests": 0
          },
          {
           "id": "gemma-4-26b-qat-4bit",
           "active_requests": 99,
           "running_providers": 47,
           "warm_providers": 405,
           "cold_providers": 154,
           "queued_requests": 0
          },
          {
           "id": "qwen3.5-35b-a3b",
           "active_requests": 2,
           "running_providers": 2,
           "warm_providers": 53,
           "cold_providers": 217,
           "queued_requests": 0
          }
         ]
        }
        """.data(using: .utf8)!

    private static let fixturePricingJSON: Data = """
        {
         "prices": [
          {
           "model": "EigenLabs/Qwen3.8-27B-4bit-mtp",
           "input_price": 50000,
           "output_price": 2200000
          },
          {
           "model": "gemma-4-26b",
           "input_price": 42000,
           "output_price": 220000
          },
          {
           "model": "gemma-4-26b-8bit",
           "input_price": 42000,
           "output_price": 220000
          },
          {
           "model": "gemma-4-26b-qat-4bit",
           "input_price": 42000,
           "output_price": 220000
          },
          {
           "model": "gpt-oss-20b",
           "input_price": 18000,
           "output_price": 90000
          },
          {
           "model": "nvidia-nemotron-3.5-lightning",
           "input_price": 39000,
           "output_price": 180000
          },
          {
           "model": "qwen3.5-35b-a3b",
           "input_price": 80000,
           "output_price": 750000
          },
          {
           "model": "Qwen3.5-9B",
           "input_price": 80000,
           "output_price": 130000
          },
          {
           "model": "qwen3.6-35b-a3b-vl-mtp-mxfp8",
           "input_price": 50000,
           "output_price": 700000
          },
          {
           "model": "qwen3.8-flash-next",
           "input_price": 130000,
           "output_price": 400000
          },
          {
           "model": "qwen3-vl-30b-a3b-instruct",
           "input_price": 90000,
           "output_price": 400000
          },
          {
           "model": "ternary-bonsai-2-27b",
           "input_price": 75000,
           "output_price": 500000
          }
         ]
        }
        """.data(using: .utf8)!

    // MARK: - helpers (mirrors PickerEntryTests.swift's style)

    private func model(
        _ id: String,
        displayName: String? = nil,
        sizeGb: Double = 10,
        minRamGb: Int? = nil
    ) -> CatalogModel {
        CatalogModel(
            id: id,
            s3Name: id,
            displayName: displayName ?? id,
            sizeGb: sizeGb,
            minRamGb: minRamGb,
            r2Prefix: "v2/\(id)/v1"
        )
    }

    private func row(_ m: CatalogModel) -> Start.PickerCatalogRow {
        Start.PickerCatalogRow(model: m, displayName: m.displayName)
    }

    private func demand(active: Int, running: Int, warm: Int, cold: Int) -> Start.PickerModelDemand {
        Start.PickerModelDemand(
            activeRequests: active,
            runningProviders: running,
            warmProviders: warm,
            coldProviders: cold)
    }

    // MARK: - Signal formula: active / max(1, warm+cold) * output_price

    @Test("signal equals active / max(1, warm+cold) * output_price")
    func signalFormula() {
        // 10 active / (3 warm + 2 cold) * 2.0 price == 4.0
        let d = demand(active: 10, running: 4, warm: 3, cold: 2)
        #expect(Start.pickerDemandSignal(d, outputPrice: 2.0) == 4.0)
    }

    @Test("zero holders (warm+cold == 0) does not divide by zero")
    func zeroHoldersNoDivideByZero() {
        // max(1, 0) == 1, so signal is active * price, not a crash/NaN/inf.
        let d = demand(active: 7, running: 1, warm: 0, cold: 0)
        let signal = Start.pickerDemandSignal(d, outputPrice: 3.0)
        #expect(signal == 21.0)
        #expect(signal.isFinite)
    }

    // MARK: - Tier cutoffs at 50% / 10% of the top signal

    @Test("50% of top is high, 10% of top is medium, above 0 is low (exact boundaries)")
    func tierCutoffBoundaries() {
        // warm=1, cold=0, price=1.0 for every model, so signal == activeRequests exactly.
        let snapshot = Start.PickerDemandSnapshot(
            demandByModelID: [
                "top": demand(active: 100, running: 10, warm: 1, cold: 0),
                "half": demand(active: 50, running: 5, warm: 1, cold: 0),      // exactly 50% of top
                "tenth": demand(active: 10, running: 2, warm: 1, cold: 0),     // exactly 10% of top
                "low": demand(active: 5, running: 1, warm: 1, cold: 0),       // 5% of top, > 0
            ],
            outputPriceByModelID: ["top": 1.0, "half": 1.0, "tenth": 1.0, "low": 1.0]
        )
        let tiers = Start.pickerDemandTiers(modelIDs: ["top", "half", "tenth", "low"], snapshot: snapshot)

        #expect(tiers["top"] == .high)
        #expect(tiers["half"] == .high, "exactly 50% of the top signal must be high at the boundary")
        #expect(tiers["tenth"] == .medium, "exactly 10% of the top signal must be medium at the boundary")
        #expect(tiers["low"] == .low, "above 0 but below the medium cutoff is low")
    }

    // MARK: - Zero traffic overrides price

    @Test("active == 0 && running == 0 is 'no traffic right now' regardless of price")
    func zeroTrafficRegardlessOfPrice() {
        let snapshot = Start.PickerDemandSnapshot(
            demandByModelID: [
                "top": demand(active: 10, running: 5, warm: 1, cold: 0),
                "zero": demand(active: 0, running: 0, warm: 2, cold: 3),
            ],
            // "zero" has by far the highest listed price -- must not matter.
            outputPriceByModelID: ["top": 1.0, "zero": 999_999.0]
        )
        let tiers = Start.pickerDemandTiers(modelIDs: ["top", "zero"], snapshot: snapshot)

        #expect(tiers["zero"] == .noTrafficNow)
        #expect(tiers["top"] == .high)
    }

    // MARK: - Missing from capacity is "unknown", and sorts after known models

    @Test("a model absent from the snapshot's demandByModelID is demand: unknown")
    func unknownTierForMissingModel() {
        let snapshot = Start.PickerDemandSnapshot(
            demandByModelID: ["known": demand(active: 5, running: 2, warm: 1, cold: 0)],
            outputPriceByModelID: ["known": 1.0]
        )
        let tiers = Start.pickerDemandTiers(modelIDs: ["known", "missing"], snapshot: snapshot)

        #expect(tiers["known"] == .high)
        #expect(tiers["missing"] == .unknown)
    }

    @Test("an unknown-tier entry sorts after known entries in its section, even when much bigger")
    func unknownSortsAfterKnownRegardlessOfSize() {
        let knownModel = model("org/known-small", sizeGb: 5)
        let unknownModel = model("org/unknown-big", sizeGb: 100)
        let snapshot = Start.PickerDemandSnapshot(
            demandByModelID: ["org/known-small": demand(active: 5, running: 2, warm: 1, cold: 0)],
            outputPriceByModelID: ["org/known-small": 1.0]
        )

        // Feed the bigger unknown row first to prove the sort actually reorders it.
        let entries = Start.buildPickerEntries(
            rows: [row(unknownModel), row(knownModel)],
            downloadedIDs: [],
            localMemoryByID: [:],
            resumableIDs: [],
            memoryGb: 128,
            demand: snapshot
        )

        #expect(entries.map(\.id) == ["org/known-small", "org/unknown-big"])
        #expect(entries[0].demandTier == .high)
        #expect(entries[1].demandTier == .unknown)
    }

    // MARK: - Sort: downloaded before not-downloaded, then signal desc, then size desc

    @Test("downloaded before not-downloaded; within each section, signal desc then size desc")
    func sortBySignalThenSize() {
        let dlHigh = model("org/dl-high", sizeGb: 8)
        let dlTieBig = model("org/dl-tie-big", sizeGb: 30)
        let dlTieSmall = model("org/dl-tie-small", sizeGb: 10)
        let ndHigh = model("org/nd-high", sizeGb: 5)
        let ndLow = model("org/nd-low", sizeGb: 50)

        // warm=1, cold=0, price=1.0 everywhere, so signal == activeRequests exactly.
        let snapshot = Start.PickerDemandSnapshot(
            demandByModelID: [
                "org/dl-high": demand(active: 100, running: 1, warm: 1, cold: 0),
                "org/dl-tie-big": demand(active: 50, running: 1, warm: 1, cold: 0),
                "org/dl-tie-small": demand(active: 50, running: 1, warm: 1, cold: 0),
                // Not-downloaded, but its signal (1000) dwarfs every downloaded model's —
                // downloaded-first must still win the section ordering.
                "org/nd-high": demand(active: 1000, running: 1, warm: 1, cold: 0),
                "org/nd-low": demand(active: 20, running: 1, warm: 1, cold: 0),
            ],
            outputPriceByModelID: [
                "org/dl-high": 1.0, "org/dl-tie-big": 1.0, "org/dl-tie-small": 1.0,
                "org/nd-high": 1.0, "org/nd-low": 1.0,
            ]
        )

        let entries = Start.buildPickerEntries(
            rows: [row(dlHigh), row(dlTieBig), row(dlTieSmall), row(ndHigh), row(ndLow)],
            downloadedIDs: ["org/dl-high", "org/dl-tie-big", "org/dl-tie-small"],
            localMemoryByID: [:],
            resumableIDs: [],
            memoryGb: 128,
            demand: snapshot
        )

        #expect(entries.map(\.id) == [
            "org/dl-high",       // downloaded, signal 100
            "org/dl-tie-big",    // downloaded, signal 50, size 30 (tie-break winner over the next)
            "org/dl-tie-small",  // downloaded, signal 50, size 10
            "org/nd-high",       // not downloaded, signal 1000 -- still after every downloaded entry
            "org/nd-low",        // not downloaded, signal 20
        ])
    }

    // MARK: - Pre-select lands on the higher-signal downloaded+fitting entry, even when smaller

    @Test("the higher-signal downloaded+fitting entry sorts first even when it's the smaller model")
    func higherSignalDownloadedEntryFirstEvenWhenSmaller() {
        let bigLowSignal = model("org/big-low-signal", sizeGb: 30)
        let smallHighSignal = model("org/small-high-signal", sizeGb: 5)

        let snapshot = Start.PickerDemandSnapshot(
            demandByModelID: [
                "org/big-low-signal": demand(active: 10, running: 1, warm: 1, cold: 0),
                "org/small-high-signal": demand(active: 200, running: 1, warm: 1, cold: 0),
            ],
            outputPriceByModelID: ["org/big-low-signal": 1.0, "org/small-high-signal": 1.0]
        )

        // 64 GB box: both models are well within budget (memoryGb - pickerOSReserveGb), so
        // both are eligible for the TUI's `firstIndex(where: downloaded && fits)` pre-select.
        let memoryGb = 64.0
        let entries = Start.buildPickerEntries(
            rows: [row(bigLowSignal), row(smallHighSignal)],
            downloadedIDs: ["org/big-low-signal", "org/small-high-signal"],
            localMemoryByID: [:],
            resumableIDs: [],
            memoryGb: memoryGb,
            demand: snapshot
        )

        #expect(entries.allSatisfy { Start.modelFitsBudget(sizeGb: $0.sizeGb, memoryGb: memoryGb) })

        // This mirrors the TUI's pre-select: entries.firstIndex(where: { $0.downloaded && fits }).
        let preSelected = entries.first(where: {
            $0.downloaded && Start.modelFitsBudget(sizeGb: $0.sizeGb, memoryGb: memoryGb)
        })
        #expect(preSelected?.id == "org/small-high-signal", "pre-select must land on the higher-signal model")
        #expect(
            (preSelected?.sizeGb ?? .infinity) < (entries.first(where: { $0.id == "org/big-low-signal" })?.sizeGb ?? 0),
            "the pre-selected model must be smaller than the lower-signal alternative")
    }

    // MARK: - Capacity/pricing fetch failure falls back to the size-only order with no labels exactly

    @Test("demand: nil is byte-identical to omitting the demand parameter (the size-only order with no labels)")
    func nilDemandMatchesSizeOnlyOrder() {
        let a = model("org/a-small-dl", sizeGb: 4, minRamGb: 8)
        let b = model("org/b-big-dl", sizeGb: 40, minRamGb: 8)
        let c = model("org/c-avail", sizeGb: 20, minRamGb: 8)

        let withoutDemandParam = Start.buildPickerEntries(
            rows: [row(a), row(b), row(c)],
            downloadedIDs: ["org/a-small-dl", "org/b-big-dl"],
            localMemoryByID: ["org/a-small-dl": 4, "org/b-big-dl": 40],
            resumableIDs: [],
            memoryGb: 64
        )
        let withExplicitNilDemand = Start.buildPickerEntries(
            rows: [row(a), row(b), row(c)],
            downloadedIDs: ["org/a-small-dl", "org/b-big-dl"],
            localMemoryByID: ["org/a-small-dl": 4, "org/b-big-dl": 40],
            resumableIDs: [],
            memoryGb: 64,
            demand: nil
        )

        #expect(withoutDemandParam == withExplicitNilDemand)
        // Same order as the pre-existing "downloaded first, then larger first" rule.
        #expect(withoutDemandParam.map(\.id) == ["org/b-big-dl", "org/a-small-dl", "org/c-avail"])
        #expect(withoutDemandParam.allSatisfy { $0.demandTier == nil }, "no demand data means no label")
    }

    @Test("parsePickerDemandSnapshot returns nil when the capacity JSON fails to decode")
    func malformedCapacityJSONReturnsNil() {
        let badCapacity = "not json".data(using: .utf8)!
        let goodPricing = #"{"prices":[{"model":"m","input_price":1,"output_price":2}]}"#.data(using: .utf8)!
        #expect(Start.parsePickerDemandSnapshot(capacityJSON: badCapacity, pricingJSON: goodPricing) == nil)
    }

    @Test("parsePickerDemandSnapshot returns nil when the pricing JSON fails to decode")
    func malformedPricingJSONReturnsNil() {
        let goodCapacity = """
            {"models":[{"id":"m","active_requests":1,"running_providers":1,"warm_providers":1,"cold_providers":0,"queued_requests":0}]}
            """.data(using: .utf8)!
        let badPricing = "not json".data(using: .utf8)!
        #expect(Start.parsePickerDemandSnapshot(capacityJSON: goodCapacity, pricingJSON: badPricing) == nil)
    }

    // MARK: - Row labels
    //
    // The fallback (non-TTY) picker's row rendering (`fallbackPicker` in
    // StartCommand+Picker.swift) prints directly to stdout via `print(...)` inside an
    // `async throws` method that also downloads models -- it is not a pure
    // text-rendering function we can call and inspect a string from, and the TUI's
    // `render` closure is similarly IO-only (writes ANSI bytes straight to
    // STDOUT_FILENO from inside `runModelPicker`). This test covers `pickerDemandLabel`,
    // the pure function both call sites use for row text; both pickers render the same
    // `entries` ordering.
    @Test("pickerDemandLabel renders the five row labels")
    func demandLabels() {
        #expect(Start.pickerDemandLabel(.high) == "demand: high")
        #expect(Start.pickerDemandLabel(.medium) == "demand: medium")
        #expect(Start.pickerDemandLabel(.low) == "demand: low")
        #expect(Start.pickerDemandLabel(.noTrafficNow) == "no traffic right now")
        #expect(Start.pickerDemandLabel(.unknown) == "demand: unknown")
    }

    // MARK: - Replay of recorded 2026-09-28T14:00Z capacity + pricing fixtures

    private static let fixtureRowsWithoutQwen38 = [
        ("Qwen3.5-9B", 5.5),
        ("gpt-oss-20b", 12.0),
        ("nvidia-nemotron-3.5-lightning", 20.0),
        ("qwen3.6-35b-a3b-vl-mtp-mxfp8", 20.0),
        ("gemma-4-26b-8bit", 15.0),
        ("ternary-bonsai-2-27b", 16.0),
        ("gemma-4-26b-qat-4bit", 15.0),
        ("qwen3.5-35b-a3b", 20.0),
    ]

    @Test("fixture replay without Qwen3.8 (non-M5 Mac) -- exact order and tiers")
    func fixtureReplayWithoutQwen38() throws {
        let snapshot = try #require(
            Start.parsePickerDemandSnapshot(
                capacityJSON: Self.fixtureCapacityJSON, pricingJSON: Self.fixturePricingJSON))

        let rows = Self.fixtureRowsWithoutQwen38.map { row(model($0.0, sizeGb: $0.1)) }

        let entries = Start.buildPickerEntries(
            rows: rows,
            downloadedIDs: [],
            localMemoryByID: [:],
            resumableIDs: [],
            memoryGb: 128,
            demand: snapshot
        )

        #expect(entries.map(\.id) == [
            "gemma-4-26b-qat-4bit",
            "gpt-oss-20b",
            "Qwen3.5-9B",
            "nvidia-nemotron-3.5-lightning",
            "qwen3.6-35b-a3b-vl-mtp-mxfp8",
            "qwen3.5-35b-a3b",
            "ternary-bonsai-2-27b",
            "gemma-4-26b-8bit",
        ])

        let tierByID: [String: Start.PickerDemandTier] =
            Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.demandTier) }).compactMapValues { $0 }

        #expect(tierByID["gemma-4-26b-qat-4bit"] == .high)
        #expect(tierByID["gpt-oss-20b"] == .high)
        #expect(tierByID["Qwen3.5-9B"] == .high)
        #expect(tierByID["nvidia-nemotron-3.5-lightning"] == .high)
        #expect(tierByID["qwen3.6-35b-a3b-vl-mtp-mxfp8"] == .medium)
        #expect(tierByID["qwen3.5-35b-a3b"] == .medium)
        #expect(tierByID["ternary-bonsai-2-27b"] == .low)
        #expect(tierByID["gemma-4-26b-8bit"] == .noTrafficNow)
    }

    @Test("fixture replay with Qwen3.8 listed (M5 Mac) -- Qwen3.8 high, gemma-4-26b-8bit no traffic, all others low")
    func fixtureReplayWithQwen38() throws {
        let snapshot = try #require(
            Start.parsePickerDemandSnapshot(
                capacityJSON: Self.fixtureCapacityJSON, pricingJSON: Self.fixturePricingJSON))

        let rows = Self.fixtureRowsWithoutQwen38.map { row(model($0.0, sizeGb: $0.1)) }
            + [row(model("EigenLabs/Qwen3.8-27B-4bit-mtp", sizeGb: 15.0))]

        let entries = Start.buildPickerEntries(
            rows: rows,
            downloadedIDs: [],
            localMemoryByID: [:],
            resumableIDs: [],
            memoryGb: 128,
            demand: snapshot
        )

        // The signal-desc-then-size-desc sort rule applies within the "low" tier
        // too, not just between tiers; the expected tiers below follow directly
        // from that rule for this fixture.
        #expect(entries.map(\.id) == [
            "EigenLabs/Qwen3.8-27B-4bit-mtp",
            "gemma-4-26b-qat-4bit",
            "gpt-oss-20b",
            "Qwen3.5-9B",
            "nvidia-nemotron-3.5-lightning",
            "qwen3.6-35b-a3b-vl-mtp-mxfp8",
            "qwen3.5-35b-a3b",
            "ternary-bonsai-2-27b",
            "gemma-4-26b-8bit",
        ])

        let tierByID: [String: Start.PickerDemandTier] =
            Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.demandTier) }).compactMapValues { $0 }

        #expect(tierByID["EigenLabs/Qwen3.8-27B-4bit-mtp"] == .high)
        #expect(tierByID["gemma-4-26b-8bit"] == .noTrafficNow)
        for id in Self.fixtureRowsWithoutQwen38.map(\.0) where id != "gemma-4-26b-8bit" {
            #expect(tierByID[id] == .low, "\(id) must drop to low once Qwen3.8 raises the top signal")
        }
    }

    // MARK: - fetchPickerDemandSnapshot failure paths (stubbed transport, no real network)
    //
    // Each test builds its own `URLSessionConfiguration.ephemeral` with
    // `PickerDemandFetchURLProtocol` registered and passes the resulting
    // `URLSession` through `fetchPickerDemandSnapshot`'s `urlSession`
    // parameter, so nothing here touches the network. The suite is marked
    // `.serialized` (see the `@Suite` attribute above) because the stub's
    // response fixtures live in `nonisolated(unsafe) static var`s shared by
    // every test in this file, mirroring the stub pattern in
    // `ProviderCoreTests/Models/ModelCatalogTests.swift`.

    @Test("fetchPickerDemandSnapshot returns nil when the capacity endpoint responds 500")
    func fetchReturnsNilOnCapacityServerError() async {
        PickerDemandFetchURLProtocol.capacityStatusCode = 500
        PickerDemandFetchURLProtocol.capacityBody = Self.fixtureCapacityJSON
        PickerDemandFetchURLProtocol.pricingStatusCode = 200
        PickerDemandFetchURLProtocol.pricingBody = Self.fixturePricingJSON
        PickerDemandFetchURLProtocol.failWithError = nil

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PickerDemandFetchURLProtocol.self]
        let session = URLSession(configuration: config)

        let snapshot = await Start.fetchPickerDemandSnapshot(
            coordinatorURL: "wss://picker-demand-fixture.example/ws/provider",
            urlSession: session)

        #expect(snapshot == nil)
    }

    @Test("fetchPickerDemandSnapshot returns nil when the transport fails with a URLError")
    func fetchReturnsNilOnTransportError() async {
        PickerDemandFetchURLProtocol.capacityStatusCode = 200
        PickerDemandFetchURLProtocol.capacityBody = Self.fixtureCapacityJSON
        PickerDemandFetchURLProtocol.pricingStatusCode = 200
        PickerDemandFetchURLProtocol.pricingBody = Self.fixturePricingJSON
        PickerDemandFetchURLProtocol.failWithError = URLError(.notConnectedToInternet)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PickerDemandFetchURLProtocol.self]
        let session = URLSession(configuration: config)

        let snapshot = await Start.fetchPickerDemandSnapshot(
            coordinatorURL: "wss://picker-demand-fixture.example/ws/provider",
            urlSession: session)

        #expect(snapshot == nil)
    }

    @Test("fetchPickerDemandSnapshot returns the parsed snapshot when both endpoints succeed")
    func fetchReturnsSnapshotOnSuccess() async throws {
        PickerDemandFetchURLProtocol.capacityStatusCode = 200
        PickerDemandFetchURLProtocol.capacityBody = Self.fixtureCapacityJSON
        PickerDemandFetchURLProtocol.pricingStatusCode = 200
        PickerDemandFetchURLProtocol.pricingBody = Self.fixturePricingJSON
        PickerDemandFetchURLProtocol.failWithError = nil

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PickerDemandFetchURLProtocol.self]
        let session = URLSession(configuration: config)

        let snapshot = try #require(
            await Start.fetchPickerDemandSnapshot(
                coordinatorURL: "wss://picker-demand-fixture.example/ws/provider",
                urlSession: session))

        let expected = try #require(
            Start.parsePickerDemandSnapshot(
                capacityJSON: Self.fixtureCapacityJSON, pricingJSON: Self.fixturePricingJSON))
        #expect(snapshot == expected)
    }
}

/// Stub transport for `fetchPickerDemandSnapshot`'s `urlSession` parameter.
/// Routes on the request path so the two concurrent GETs
/// (`/v1/models/capacity`, `/v1/pricing`) can be answered independently;
/// `failWithError`, when set, fails every request instead (models an
/// unreachable coordinator). Registered per test via
/// `URLSessionConfiguration.protocolClasses`, never on `.shared`, so it never
/// intercepts real network traffic.
private final class PickerDemandFetchURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var capacityBody = Data()
    nonisolated(unsafe) static var capacityStatusCode = 200
    nonisolated(unsafe) static var pricingBody = Data()
    nonisolated(unsafe) static var pricingStatusCode = 200
    nonisolated(unsafe) static var failWithError: URLError?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if let failure = Self.failWithError {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let body: Data
        let statusCode: Int
        switch url.path {
        case "/v1/models/capacity":
            body = Self.capacityBody
            statusCode = Self.capacityStatusCode
        case "/v1/pricing":
            body = Self.pricingBody
            statusCode = Self.pricingStatusCode
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: statusCode, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
