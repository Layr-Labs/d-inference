import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// Answers catalog requests from a per-host table, so each test owns its own
/// reply and request log. No request leaves the process.
private final class PickerCatalogURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requests: [String: [URL]] = [:]

    static func register(host: String, reply: Reply) {
        lock.withLock { replies[host] = reply }
    }

    static func requests(host: String) -> [URL] {
        lock.withLock { requests[host] ?? [] }
    }

    static func forget(host: String) {
        lock.withLock {
            replies[host] = nil
            requests[host] = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let host = url.host ?? ""
        let reply = Self.lock.withLock { () -> Reply? in
            Self.requests[host, default: []].append(url)
            return Self.replies[host]
        } ?? Reply(status: 404, body: Data())
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(reply.body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func catalogModel(
    _ id: String,
    displayName: String? = nil,
    sizeGb: Double = 4,
    minRamGb: Int? = nil,
    metadata: [String: JSONValue]? = nil
) -> CatalogModel {
    CatalogModel(
        id: id, s3Name: id, displayName: displayName ?? id, sizeGb: sizeGb,
        minRamGb: minRamGb, metadata: metadata)
}

/// The catalog picker flow before any download: fetch, filter, size the
/// rows for this Mac, and resolve the non-terminal answer. The snapshot has
/// no hardware, so nothing on disk is scanned and the 16 GB default applies.
@Suite("Start catalog picker flow")
struct CatalogPickerFlowTests {
    private struct CatalogBody: Encodable {
        let models: [CatalogModel]
        let aliases: [CatalogAlias]
    }

    private struct Fixture {
        let host: String
        let session: URLSession

        var coordinatorURL: String { "wss://\(host)/ws/provider" }

        init(status: Int = 200, models: [CatalogModel]) throws {
            host = "catalog-\(UUID().uuidString.lowercased()).invalid"
            let body = try JSONEncoder().encode(CatalogBody(models: models, aliases: []))
            PickerCatalogURLProtocol.register(
                host: host, reply: .init(status: status, body: status == 200 ? body : Data("unavailable".utf8)))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PickerCatalogURLProtocol.self]
            session = URLSession(configuration: configuration)
        }

        func tearDown() {
            session.invalidateAndCancel()
            PickerCatalogURLProtocol.forget(host: host)
        }
    }

    private var snapshot: RuntimeSnapshot {
        RuntimeSnapshot(
            configPath: FileManager.default.temporaryDirectory.appendingPathComponent("absent-provider.toml"),
            configFileExists: false,
            config: ProviderConfig(provider: ProviderSettings(name: "picker-fixture")),
            hardware: nil,
            hardwareError: nil,
            models: [])
    }

    private func pick(
        _ fixture: Fixture,
        answers: [String?]
    ) async throws -> (ids: [String], reads: Int) {
        let start = try Start.parse([])
        var remaining = answers
        var reads = 0
        let ids = try await start.interactiveCatalogPicker(
            snapshot: snapshot,
            config: snapshot.config,
            coordinatorURL: fixture.coordinatorURL,
            runtimeCapabilities: [],
            urlSession: fixture.session,
            isInteractive: false,
            readInput: {
                reads += 1
                return remaining.isEmpty ? nil : remaining.removeFirst()
            })
        return (ids, reads)
    }

    private func expectExitFailure(
        _ fixture: Fixture,
        answers: [String?] = [],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        do {
            let result = try await pick(fixture, answers: answers)
            Issue.record("expected ExitCode.failure, got \(result.ids)", sourceLocation: sourceLocation)
        } catch let code as ExitCode {
            #expect(code == .failure, sourceLocation: sourceLocation)
        } catch {
            Issue.record("expected ExitCode.failure, got \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test("the picker asks the coordinator for text models with aliases")
    func requestsTextCatalogWithAliases() async throws {
        let fixture = try Fixture(models: [catalogModel("org/small", sizeGb: 4)])
        defer { fixture.tearDown() }

        let result = try await pick(fixture, answers: [""])

        #expect(result.ids == [])
        let requests = PickerCatalogURLProtocol.requests(host: fixture.host)
        #expect(requests.count == 1)
        let url = try #require(requests.first)
        #expect(url.scheme == "https")
        #expect(url.path == "/v1/models/catalog")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "type", value: "text")))
        #expect(query.contains(URLQueryItem(name: "include_aliases", value: "1")))
    }

    @Test("a catalog fetch error stops start")
    func catalogFetchFailureExits() async throws {
        let fixture = try Fixture(status: 503, models: [])
        defer { fixture.tearDown() }
        await expectExitFailure(fixture)
    }

    @Test("an empty catalog stops start")
    func emptyCatalogExits() async throws {
        let fixture = try Fixture(models: [])
        defer { fixture.tearDown() }
        await expectExitFailure(fixture)
    }

    @Test("a catalog with only hidden rows stops start")
    func onlyHiddenRowsExits() async throws {
        let fixture = try Fixture(models: [
            catalogModel("org/hidden", sizeGb: 4, metadata: ["hidden_from_picker": .bool(true)]),
            catalogModel("org/standalone", sizeGb: 4, metadata: ["hide_standalone": .bool(true)]),
            catalogModel("org/old", displayName: "Old Rollback Build", sizeGb: 4),
            catalogModel("gemma-4-26b-8bit", sizeGb: 4),
        ])
        defer { fixture.tearDown() }
        await expectExitFailure(fixture)
    }

    @Test("no row is offered when every model needs more RAM than this Mac has")
    func nothingFitsExits() async throws {
        let fixture = try Fixture(models: [
            catalogModel("org/large-a", sizeGb: 20, minRamGb: 64),
            catalogModel("org/large-b", sizeGb: 30, minRamGb: 32),
        ])
        defer { fixture.tearDown() }
        await expectExitFailure(fixture)
    }

    @Test("an empty answer and end of input both cancel without a selection")
    func emptyAnswerAndEndOfInputCancel() async throws {
        let fixture = try Fixture(models: [
            catalogModel("org/small", sizeGb: 4, minRamGb: 8),
            catalogModel("org/too-big", sizeGb: 14),
        ])
        defer { fixture.tearDown() }

        let blank = try await pick(fixture, answers: ["  "])
        #expect(blank.ids == [])
        #expect(blank.reads == 1)

        let endOfInput = try await pick(fixture, answers: [nil])
        #expect(endOfInput.ids == [])
        #expect(endOfInput.reads == 1)
    }

    @Test("an out-of-range number stops start")
    func outOfRangeAnswerExits() async throws {
        let fixture = try Fixture(models: [catalogModel("org/small", sizeGb: 4)])
        defer { fixture.tearDown() }
        await expectExitFailure(fixture, answers: ["9"])
    }

    @Test("a pick that does not fit stops start before any download")
    func wontFitAnswerExits() async throws {
        // Larger rows sort first, so row 1 is the 14 GB model. A row to
        // download is budgeted at its size x 1.2 in GiB (about 15.6 GiB);
        // the 16 GB budget is 7.5 GiB.
        let fixture = try Fixture(models: [
            catalogModel("org/small", sizeGb: 4),
            catalogModel("org/too-big", sizeGb: 14),
        ])
        defer { fixture.tearDown() }
        await expectExitFailure(fixture, answers: ["1"])
    }

    @Test("'all' stops start when no row fits")
    func allWithNothingFittingExits() async throws {
        let fixture = try Fixture(models: [catalogModel("org/too-big", sizeGb: 14)])
        defer { fixture.tearDown() }
        await expectExitFailure(fixture, answers: ["all"])
    }
}

/// Pure catalog-row rules that run before the picker shows anything.
@Suite("Start picker catalog rows")
struct PickerCatalogRowTests {
    private func alias(
        displayName: String,
        desired: String,
        previous: String? = nil,
        retired: [String]? = nil
    ) throws -> CatalogAlias {
        var object: [String: Any] = ["id": displayName.lowercased(), "display_name": displayName, "desired_build": desired]
        if let previous { object["previous_build"] = previous }
        if let retired { object["retired_builds"] = retired }
        return try JSONDecoder().decode(
            CatalogAlias.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func rows(_ models: [CatalogModel], aliases: [CatalogAlias] = []) -> [Start.PickerCatalogRow] {
        Start.pickerCatalogRows(
            catalog: Start.evaluateEligiblePickerCatalog(
                models: models, aliases: aliases, runtimeCapabilities: []))
    }

    @Test("without aliases, hidden, standalone-only and rollback rows are dropped")
    func hiddenRowsDropped() {
        let result = rows([
            catalogModel("org/visible", displayName: "Visible"),
            catalogModel("org/hidden", metadata: ["hidden_from_picker": .bool(true)]),
            catalogModel("org/standalone", metadata: ["hide_standalone": .bool(true)]),
            catalogModel("org/flag-false", displayName: "Flag False", metadata: ["hidden_from_picker": .bool(false)]),
            catalogModel("org/rollback", displayName: "Model (ROLLBACK)"),
        ])
        #expect(result.map(\.model.id) == ["org/visible", "org/flag-false"])
        #expect(result.map(\.displayName) == ["Visible", "Flag False"])
    }

    @Test("with the Gemma QAT build listed, it takes the public name and hides the older builds")
    func gemmaQATReplacesPublicBuild() {
        let result = rows([
            catalogModel("gemma-4-26b", displayName: "Gemma 4 26B (bf16)"),
            catalogModel("gemma-4-26b-qat-4bit", displayName: "Gemma 4 26B QAT"),
            catalogModel("gemma-4-26b-8bit", displayName: "Gemma 4 26B 8-bit"),
        ])
        #expect(result.map(\.model.id) == ["gemma-4-26b-qat-4bit"])
        #expect(result.map(\.displayName) == ["Gemma 4 26B"])
    }

    @Test("without the Gemma QAT build, only the rollback build is hidden")
    func gemmaWithoutQATKeepsPublicBuild() {
        let result = rows([
            catalogModel("gemma-4-26b", displayName: "Gemma 4 26B (bf16)"),
            catalogModel("gemma-4-26b-8bit", displayName: "Gemma 4 26B 8-bit"),
        ])
        #expect(result.map(\.model.id) == ["gemma-4-26b"])
        #expect(result.map(\.displayName) == ["Gemma 4 26B (bf16)"])
    }

    @Test("alias builds are hidden except the one shown under the alias name")
    func aliasHidesRetiredAndPreviousBuilds() throws {
        let result = rows(
            [
                catalogModel("org/v3", displayName: "v3"),
                catalogModel("org/v2", displayName: "v2"),
                catalogModel("org/v1", displayName: "v1"),
                catalogModel("org/other", displayName: "Other"),
                catalogModel("org/secret", displayName: "Secret", metadata: ["hidden_from_picker": .bool(true)]),
            ],
            aliases: [try alias(displayName: "Family", desired: "org/v3", previous: "org/v2", retired: ["org/v1"])])

        #expect(result.map(\.model.id) == ["org/v3", "org/other"])
        #expect(result.map(\.displayName) == ["Family", "Other"])
    }

    @Test("an alias whose builds are not in the catalog adds no row")
    func aliasWithoutListedBuilds() throws {
        let catalog = Start.evaluateEligiblePickerCatalog(
            models: [catalogModel("org/plain", displayName: "Plain")],
            aliases: [try alias(displayName: "Ghost", desired: "org/missing")],
            runtimeCapabilities: [])
        #expect(catalog.sourceHasAliases)
        #expect(catalog.hiddenBuildIDs == ["org/missing"])
        #expect(catalog.aliasDisplayByBuildID.isEmpty)
        #expect(Start.pickerCatalogRows(catalog: catalog).map(\.displayName) == ["Plain"])
    }

    @Test("the fit budget is the load cap less the load headroom")
    func fitBudgetBoundary() {
        // 16 GiB: cap = min(0.9 x 16, 16 - 2) = 14 GiB, less 5.5 GiB for
        // activations and 1 GiB minimum KV = 7.5 GiB. This assumes that
        // DARKBLOOM_MEM_CAP_FRACTION and DARKBLOOM_ACTIVATION_RESERVE_GB are
        // not set.
        #expect(Start.pickerLoadBudgetGiB(memoryGb: 16) == 7.5)
        #expect(Start.modelFitsBudget(sizeGb: 7.5, memoryGb: 16))
        #expect(!Start.modelFitsBudget(sizeGb: 7.6, memoryGb: 16))
        #expect(!Start.modelFitsBudget(sizeGb: 0, memoryGb: 16))
        #expect(!Start.modelFitsBudget(sizeGb: .nan, memoryGb: 16))
        #expect(Start.pickerLoadBudgetGiB(memoryGb: 0) == 0)
        #expect(Start.pickerLoadBudgetGiB(memoryGb: 5000) == 0)
    }

    @Test("fallback rejections name the reason and the limits")
    func fallbackRejectionMessages() {
        func entry(_ id: String, _ name: String, _ size: Double) -> Start.PickerEntry {
            Start.PickerEntry(
                id: id, catalogModel: catalogModel(id, sizeGb: size), displayName: name,
                sizeGb: size, minRamGb: nil, downloaded: false)
        }
        let small = entry("org/small", "Small", 4)
        let huge = entry("org/huge", "Huge", 20)
        let usable = String(format: "%.1f", Start.pickerLoadBudgetGiB(memoryGb: 16))

        #expect(Start.resolveFallbackSelection(input: "all", entries: [huge], memoryGb: 16)
            == .rejected("No model fits in 16 GB RAM (need \u{2264} \(usable) GB per model)."))
        #expect(Start.resolveFallbackSelection(input: "1, x", entries: [small], memoryGb: 16)
            == .rejected("Invalid selection: 'x' is not a number."))
        #expect(Start.resolveFallbackSelection(input: "0", entries: [small, huge], memoryGb: 16)
            == .rejected("Invalid selection: 0 (must be 1-2)."))
        #expect(Start.resolveFallbackSelection(input: "2", entries: [small, huge], memoryGb: 16)
            == .rejected(
                "Huge (20.0 GB) needs more memory than this Mac has (16 GB RAM, ~\(usable) GB usable). Choose a smaller model."))
        #expect(Start.resolveFallbackSelection(input: " ALL ", entries: [small, huge], memoryGb: 16)
            == .selected(["org/small"]))
    }
}
