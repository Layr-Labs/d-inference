// Start picker demand ranking: fetch coordinator capacity/pricing, compute a
// per-model demand signal and tier, and label picker rows with it. Pure
// functions (signal, tiers, label, parsing) live here so the ranking is
// unit-testable; the network fetch is the only IO and returns nil on any
// failure so a slow/unreachable coordinator falls back to the size-only
// order with no labels.
import Foundation
import ProviderCore

extension Start {
    // MARK: - Picker demand types

    /// One model's row from `GET /v1/models/capacity`.
    struct PickerModelDemand: Equatable, Sendable {
        let activeRequests: Int
        let runningProviders: Int
        let warmProviders: Int
        let coldProviders: Int
    }

    /// Demand label shown on a picker row.
    enum PickerDemandTier: Equatable, Sendable {
        case high
        case medium
        case low
        case noTrafficNow
        case unknown
    }

    /// A single fetch's capacity + pricing, keyed by catalog model ID.
    struct PickerDemandSnapshot: Equatable, Sendable {
        let demandByModelID: [String: PickerModelDemand]
        let outputPriceByModelID: [String: Double]
    }

    // MARK: - Pure ranking

    /// `signal = active_requests / max(1, warm_providers + cold_providers) *
    /// output_price`. Zero holders is clamped to 1 rather than dividing by
    /// zero.
    static func pickerDemandSignal(_ demand: PickerModelDemand, outputPrice: Double) -> Double {
        let holders = demand.warmProviders + demand.coldProviders
        return Double(demand.activeRequests) / Double(max(1, holders)) * outputPrice
    }

    /// Signal per model ID that is present in `snapshot.demandByModelID`. A
    /// missing price counts as 0. Model IDs absent from the
    /// snapshot are omitted, so they never influence the top-signal cutoffs
    /// below.
    static func pickerDemandSignals(modelIDs: [String], snapshot: PickerDemandSnapshot) -> [String: Double] {
        var signals: [String: Double] = [:]
        for id in modelIDs {
            guard let demand = snapshot.demandByModelID[id] else { continue }
            let price = snapshot.outputPriceByModelID[id] ?? 0
            signals[id] = pickerDemandSignal(demand, outputPrice: price)
        }
        return signals
    }

    /// Per-model demand tier for `modelIDs`, relative to the highest signal
    /// among those same IDs. A model absent from the snapshot is `.unknown`;
    /// `active_requests == 0 && running_providers ==
    /// 0` is always `.noTrafficNow` regardless of price. A present model with
    /// signal 0 that is not "no traffic right now" (running providers with no
    /// active requests, or a missing price) still reads `.low`, not
    /// `.unknown`.
    static func pickerDemandTiers(modelIDs: [String], snapshot: PickerDemandSnapshot) -> [String: PickerDemandTier] {
        let signalByID = pickerDemandSignals(modelIDs: modelIDs, snapshot: snapshot)
        let topSignal = signalByID.values.max() ?? 0

        var tiers: [String: PickerDemandTier] = [:]
        for id in modelIDs {
            guard let demand = snapshot.demandByModelID[id] else {
                tiers[id] = .unknown
                continue
            }
            if demand.activeRequests == 0 && demand.runningProviders == 0 {
                tiers[id] = .noTrafficNow
                continue
            }
            let signal = signalByID[id] ?? 0
            if topSignal > 0, signal >= topSignal * 0.5 {
                tiers[id] = .high
            } else if topSignal > 0, signal >= topSignal * 0.1 {
                tiers[id] = .medium
            } else {
                tiers[id] = .low
            }
        }
        return tiers
    }

    /// Row text for a demand tier.
    static func pickerDemandLabel(_ tier: PickerDemandTier) -> String {
        switch tier {
        case .high: return "demand: high"
        case .medium: return "demand: medium"
        case .low: return "demand: low"
        case .noTrafficNow: return "no traffic right now"
        case .unknown: return "demand: unknown"
        }
    }

    // MARK: - Parsing

    private struct CapacityResponse: Decodable {
        let models: [CapacityModelRow]
    }

    private struct CapacityModelRow: Decodable {
        let id: String
        let activeRequests: Int
        let runningProviders: Int
        let warmProviders: Int
        let coldProviders: Int

        enum CodingKeys: String, CodingKey {
            case id
            case activeRequests = "active_requests"
            case runningProviders = "running_providers"
            case warmProviders = "warm_providers"
            case coldProviders = "cold_providers"
        }
    }

    private struct PricingResponse: Decodable {
        let prices: [PricingRow]
    }

    private struct PricingRow: Decodable {
        let model: String
        let outputPrice: Double

        enum CodingKeys: String, CodingKey {
            case model
            case outputPrice = "output_price"
        }
    }

    /// Decode `/v1/models/capacity` + `/v1/pricing` bodies into a snapshot.
    /// Returns nil if either body fails to decode, so callers can fall back
    /// to the size-only order with no labels.
    static func parsePickerDemandSnapshot(capacityJSON: Data, pricingJSON: Data) -> PickerDemandSnapshot? {
        let decoder = JSONDecoder()
        guard
            let capacity = try? decoder.decode(CapacityResponse.self, from: capacityJSON),
            let pricing = try? decoder.decode(PricingResponse.self, from: pricingJSON)
        else {
            return nil
        }

        var demandByModelID: [String: PickerModelDemand] = [:]
        for row in capacity.models {
            demandByModelID[row.id] = PickerModelDemand(
                activeRequests: row.activeRequests,
                runningProviders: row.runningProviders,
                warmProviders: row.warmProviders,
                coldProviders: row.coldProviders)
        }
        var outputPriceByModelID: [String: Double] = [:]
        for row in pricing.prices {
            outputPriceByModelID[row.model] = row.outputPrice
        }
        return PickerDemandSnapshot(demandByModelID: demandByModelID, outputPriceByModelID: outputPriceByModelID)
    }

    // MARK: - Fetch

    /// Fetch a demand snapshot from the same coordinator as the catalog.
    /// Both GETs run concurrently under a short (~3 s) timeout each, so a
    /// slow or unreachable coordinator adds about 3 s, not 6, before falling
    /// back. Returns nil on any network error, non-2xx status, or decode
    /// failure -- callers pass that straight through as `demand: nil`, which
    /// reproduces the size-only order with no labels exactly.
    static func fetchPickerDemandSnapshot(
        coordinatorURL: String,
        urlSession: URLSession = .shared
    ) async -> PickerDemandSnapshot? {
        let httpBase = coordinatorHTTPBase(coordinatorURL)
        guard
            let capacityURL = URL(string: "\(httpBase)/v1/models/capacity"),
            let pricingURL = URL(string: "\(httpBase)/v1/pricing")
        else {
            return nil
        }

        func request(_ url: URL) -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 3
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return request
        }

        do {
            async let capacityFetch = urlSession.data(for: request(capacityURL))
            async let pricingFetch = urlSession.data(for: request(pricingURL))
            let (capacityData, capacityResponse) = try await capacityFetch
            let (pricingData, pricingResponse) = try await pricingFetch

            guard
                let capacityHTTP = capacityResponse as? HTTPURLResponse, (200..<300).contains(capacityHTTP.statusCode),
                let pricingHTTP = pricingResponse as? HTTPURLResponse, (200..<300).contains(pricingHTTP.statusCode)
            else {
                return nil
            }

            return parsePickerDemandSnapshot(capacityJSON: capacityData, pricingJSON: pricingData)
        } catch {
            return nil
        }
    }
}
