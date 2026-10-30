import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

extension FeatureWaitlistAccess {
    /// Answers the place with `place` and a join with `joined` (or `place`),
    /// asking no coordinator. A join prints `joined <mac count>`.
    static func answering(_ place: FeatureWaitlistLookup, joined: FeatureWaitlistLookup? = nil) -> FeatureWaitlistAccess {
        FeatureWaitlistAccess(coordinator: CLICommandSandbox.coordinatorURL, place: { place }, join: { macCount in
            print("joined \(macCount)")
            return joined ?? place
        })
    }

    /// An account Darkbloom approved for Darkbloom Sandbox.
    static let approved = answering(FeatureWaitlistTests.sandbox(.approved))
}

/// The requests a fake transport received.
private final class RecordedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    var all: [URLRequest] { lock.withLock { requests } }
}

/// The body a request carries, also after URLSession moved it into a stream.
private func bodyText(_ request: URLRequest) -> String {
    if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return String(decoding: data, as: UTF8.self)
}

@Suite("darkbloom waitlist clusters and darkbloom waitlist sandbox")
struct FeatureWaitlistTests {
    static func sandbox(_ status: FeatureWaitlistPlace.Status, position: Int? = nil) -> FeatureWaitlistLookup {
        .place(FeatureWaitlistPlace(feature: "sandbox", status: status, position: position, requestedAt: nil, decidedAt: nil))
    }

    static let day: @Sendable (Date) -> String = { _ in "Oct 29, 2026" }

    // MARK: - Arguments

    @Test("darkbloom waitlist clusters and darkbloom waitlist sandbox parse, and refuse a bad Mac count")
    func parsing() throws {
        #expect(try Darkbloom.parseAsRoot(["waitlist"]) is Waitlist)
        #expect(try Darkbloom.parseAsRoot(["waitlist", "clusters"]) is Waitlist.Clusters)
        #expect(try Darkbloom.parseAsRoot(["waitlist", "sandbox"]) is Waitlist.Sandboxes)
        let join = try #require(try Darkbloom.parseAsRoot(["waitlist", "clusters", "join", "--macs", "3", "--json"]) as? Waitlist.Clusters.Join)
        #expect(join.macs == 3 && join.options.json)
        #expect(try #require(try Darkbloom.parseAsRoot(["waitlist", "clusters", "join"]) as? Waitlist.Clusters.Join).macs == 2)
        let status = try #require(try Darkbloom.parseAsRoot(["waitlist", "clusters", "status", "--config", "/tmp/provider.toml"])
            as? Waitlist.Clusters.Status)
        #expect(status.options.configOptions.config == "/tmp/provider.toml")
        #expect(try Darkbloom.parseAsRoot(["waitlist", "sandbox", "join"]) is Waitlist.Sandboxes.Join)
        #expect(try Darkbloom.parseAsRoot(["waitlist", "sandbox", "status", "--json"]) is Waitlist.Sandboxes.Status)
        for invalid in [["--macs", "1"], ["--macs", "5"]] {
            #expect(throws: (any Error).self, "\(invalid)") { try Waitlist.Clusters.Join.parse(invalid) }
        }
        // The cluster and sandbox groups keep their own commands.
        #expect(try Darkbloom.parseAsRoot(["cluster", "setup"]) is Cluster.Setup)
        #expect(try Darkbloom.parseAsRoot(["sandbox", "status"]) is Sandbox.Status)
    }

    @Test("darkbloom waitlist lists clusters and sandbox; the cluster and sandbox groups list no waitlist")
    func help() {
        let waitlist = Darkbloom.helpMessage(for: Waitlist.self, columns: 1_000)
        #expect(waitlist.contains("\n  clusters ") && waitlist.contains("\n  sandbox "))
        #expect(!Darkbloom.helpMessage(for: Cluster.self, columns: 1_000).contains("\n  waitlist "))
        let sandbox = Darkbloom.helpMessage(for: Sandbox.self, columns: 1_000)
        #expect(!sandbox.contains("\n  waitlist "))
        #expect(sandbox.contains("Darkbloom Sandbox is open to the accounts Darkbloom approves from its waitlist"))
    }

    // MARK: - Client

    @Test("each answer of the coordinator becomes a lookup")
    func answers() throws {
        let waitlisted = FeatureWaitlistClient.answer(status: 200, body: Data(
            #"{"feature":"cluster","status":"waitlisted","position":3,"requested_at":"2026-10-30T03:10:00.123456Z"}"#.utf8))
        guard case .place(let place) = waitlisted else { Issue.record("\(waitlisted)"); return }
        #expect(place.status == .waitlisted && place.position == 3 && place.requestedAt != nil && place.decidedAt == nil)
        guard case .place(let approved) = FeatureWaitlistClient.answer(status: 200, body: Data(
            #"{"feature":"sandbox","status":"approved","decided_at":"2026-10-30T03:10:00Z"}"#.utf8)) else {
            Issue.record("approved"); return
        }
        #expect(approved.status == .approved && approved.decidedAt != nil && approved.position == nil)
        #expect(FeatureWaitlistClient.answer(status: 404, body: Data()) == .notOffered)
        #expect(FeatureWaitlistClient.answer(status: 401, body: Data()) == .needsLogin)
        #expect(FeatureWaitlistClient.answer(status: 403, body: Data(
            #"{"error":{"type":"forbidden","message":"read-only account session"}}"#.utf8))
            == .unavailable("HTTP 403: read-only account session"))
        #expect(FeatureWaitlistClient.answer(status: 200, body: Data("not json".utf8))
            == .unavailable("the coordinator's answer could not be read"))
    }

    @Test("the token goes only to an https coordinator or this Mac's loopback")
    func base() {
        #expect(FeatureWaitlistClient.base(httpBase: "https://api.darkbloom.dev")?.absoluteString == "https://api.darkbloom.dev")
        #expect(FeatureWaitlistClient.base(httpBase: "http://127.0.0.1:8080") != nil)
        #expect(FeatureWaitlistClient.base(httpBase: "http://localhost:8080") != nil)
        #expect(FeatureWaitlistClient.base(httpBase: "http://[::1]:8080") != nil)
        for refused in ["http://api.darkbloom.dev", "ftp://api.darkbloom.dev", "https://api.darkbloom.dev?x=1", "api.darkbloom.dev"] {
            #expect(FeatureWaitlistClient.base(httpBase: refused) == nil, "\(refused)")
        }
    }

    @Test("a join posts this Mac with the login token; a read sends no body")
    func requests() async throws {
        let recorded = RecordedRequests()
        let client = FeatureWaitlistClient(base: try #require(URL(string: "https://coordinator.invalid")), token: "eigeninference-pt-1",
            transport: { request in
                recorded.append(request)
                guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                else { throw URLError(.badURL) }
                return (Data(#"{"feature":"cluster","status":"waitlisted","position":1}"#.utf8), response)
            })
        _ = await client.join(.cluster, FeatureWaitlistRequest(chip: "Apple M3 Ultra", memoryGB: 512, macCount: 2))
        _ = await client.place(.sandbox)
        try #require(recorded.all.count == 2)
        let (join, read) = (recorded.all[0], recorded.all[1])
        #expect(join.httpMethod == "POST" && join.url?.absoluteString == "https://coordinator.invalid/v1/waitlists/cluster")
        #expect(join.value(forHTTPHeaderField: "Authorization") == "Bearer eigeninference-pt-1")
        let joinBody = try #require(join.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: joinBody) as? [String: Any])
        #expect(body["chip"] as? String == "Apple M3 Ultra" && body["memory_gb"] as? Int == 512 && body["mac_count"] as? Int == 2)
        #expect(read.httpMethod == "GET" && read.url?.path == "/v1/waitlists/sandbox" && read.httpBody == nil)
        let offline = FeatureWaitlistClient(base: try #require(URL(string: "https://coordinator.invalid")), token: nil,
                                            transport: { _ in throw URLError(.cannotFindHost) })
        guard case .unavailable = await offline.place(.cluster) else { Issue.record("an unreachable coordinator"); return }
    }

    // MARK: - Lines

    @Test("each place reads plainly, for clusters and for Darkbloom Sandbox")
    func lines() {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let cluster = FeatureWaitlistView(feature: .cluster, cli: "darkbloom", coordinator: "https://api.darkbloom.dev", day: Self.day)
        let sandbox = FeatureWaitlistView(feature: .sandbox, cli: "darkbloom", coordinator: "https://api.darkbloom.dev", day: Self.day)
        func place(_ status: FeatureWaitlistPlace.Status, _ position: Int? = nil, requested: Date? = nil, decided: Date? = nil) -> FeatureWaitlistPlace {
            FeatureWaitlistPlace(feature: "cluster", status: status, position: position, requestedAt: requested, decidedAt: decided)
        }
        #expect(cluster.lines(place(.none)) == ["You're not on the cluster waitlist.", "  Join it: darkbloom waitlist clusters join"])
        #expect(cluster.lines(place(.waitlisted, 3, requested: date)) == [
            "You're on the cluster waitlist: #3 in line (joined Oct 29, 2026).",
            "  Darkbloom reviews accounts in the order they joined and approves them by hand.",
            "  Check again: darkbloom waitlist clusters",
        ])
        #expect(cluster.lines(place(.approved, decided: date)) == [
            "Your account is approved for clusters since Oct 29, 2026.", "  Start: darkbloom cluster",
        ])
        #expect(sandbox.lines(place(.approved)) == [
            "Your account is approved for Darkbloom Sandbox.", "  Start: darkbloom sandbox setup",
        ])
        #expect(sandbox.lines(place(.revoked, decided: date)) == [
            "Darkbloom revoked your account's access to Darkbloom Sandbox on Oct 29, 2026.",
            "  Joining again does not restore it; contact Darkbloom if you think this is a mistake.",
        ])
        #expect(sandbox.problem(.needsLogin) == ["Link this Mac to your Darkbloom account first: darkbloom login"])
        #expect(sandbox.problem(.notOffered) == ["https://api.darkbloom.dev has no waitlists yet, so there is nothing to join there."])
        #expect(sandbox.problem(.unavailable("HTTP 500: boom"))
            == ["Could not reach the Darkbloom Sandbox waitlist at https://api.darkbloom.dev: HTTP 500: boom"])
    }

    // MARK: - Commands

    @Test("waitlist clusters join sends this Mac and the login token to the configured coordinator")
    func clusterJoin() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.writeToken("eigeninference-pt-waitlist")
            CoordinatorStub.install(["/v1/waitlists/cluster": .json(200,
                #"{"feature":"cluster","status":"waitlisted","position":4,"requested_at":"2026-10-30T03:10:00.123456Z"}"#)])
            try await runCLICommand(Waitlist.Clusters.Join.self,
                                    ["waitlist", "clusters", "join", "--macs", "3", "--config", sandbox.config.path])
            let request = try #require(CoordinatorStub.requests.first)
            print("request \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "") "
                + "\(request.value(forHTTPHeaderField: "Authorization") ?? "")")
            print("body \(bodyText(request))")
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("You're on the cluster waitlist: #4 in line (joined "))
        #expect(output.contains("request POST https://coordinator.invalid/v1/waitlists/cluster Bearer eigeninference-pt-waitlist\n"))
        #expect(output.contains("\"mac_count\":3") && output.contains("\"chip\":") && output.contains("\"memory_gb\":"))
    }

    @Test("a revoked account's join shows the revocation and fails")
    func revokedJoin() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.writeToken("eigeninference-pt-waitlist")
            CoordinatorStub.install(["/v1/waitlists/cluster": .json(200, #"{"feature":"cluster","status":"revoked"}"#)])
            await exitWithCommandStatus {
                try await runCLICommand(Waitlist.Clusters.Join.self, ["waitlist", "clusters", "join", "--config", sandbox.config.path])
            }
        }
        #expect(decodedText(result.standardOutputContent).hasPrefix("Darkbloom revoked your account's access to clusters.\n"))
    }

    @Test("waitlist sandbox status prints the place as JSON, and asks for a login without a token")
    func sandboxStatus() async throws {
        let approved = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.writeToken("eigeninference-pt-waitlist")
            CoordinatorStub.install(["/v1/waitlists/sandbox": .json(200,
                #"{"feature":"sandbox","status":"approved","decided_at":"2026-10-30T03:10:00Z"}"#)])
            try await runCLICommand(Waitlist.Sandboxes.Status.self,
                                    ["waitlist", "sandbox", "status", "--json", "--config", sandbox.config.path])
        }
        let json = decodedText(approved.standardOutputContent)
        #expect(json.contains("\"status\" : \"approved\"") && json.contains("\"decided_at\" : \"2026-10-30T03:10:00Z\""))
        let anonymous = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent, \.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            CoordinatorStub.install(["/v1/waitlists/sandbox": .json(401,
                #"{"error":{"type":"authentication_error","message":"missing credentials"}}"#)])
            await exitWithCommandStatus {
                defer { print("authorization \(CoordinatorStub.requests.first?.value(forHTTPHeaderField: "Authorization") ?? "none")") }
                try await runCLICommand(Waitlist.Sandboxes.Status.self, ["waitlist", "sandbox", "status", "--config", sandbox.config.path])
            }
        }
        #expect(decodedText(anonymous.standardErrorContent).contains("Link this Mac to your Darkbloom account first: \(Sandbox.cli) login"))
        #expect(decodedText(anonymous.standardOutputContent).hasSuffix("authorization none\n"))
    }

    // MARK: - The sandbox setup gate

    @Test("an approved account goes on to check this Mac")
    func gateAdmitsApproved() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: false, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           probe: { _ in .mac(cores: 16, memoryGiB: 128) }, waitlist: .approved).run()
            }
        }
        // Without --yes or a terminal the flow stops at its own confirmation.
        #expect(decodedText(result.standardOutputContent).hasPrefix("Darkbloom Sandbox setup\n\nChecking this Mac\n"))
    }

    @Test("a coordinator without waitlists lets a setup go on")
    func gateAdmitsWithoutWaitlists() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: false, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           probe: { _ in .mac(cores: 16, memoryGiB: 128) },
                                           waitlist: .answering(.notOffered)).run()
            }
        }
        #expect(decodedText(result.standardOutputContent).hasPrefix("Darkbloom Sandbox setup\n\nChecking this Mac\n"))
    }

    @Test("a waitlisted or revoked account stops before this Mac is checked or anything is downloaded")
    func gateRefuses() async throws {
        let waitlisted = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                defer { print("requests \(CoordinatorStub.requests.count)") }
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           probe: { _ in .mac(cores: 16, memoryGiB: 128) },
                                           waitlist: .answering(FeatureWaitlistTests.sandbox(.waitlisted, position: 2))).run()
            }
        }
        let output = decodedText(waitlisted.standardOutputContent)
        #expect(output.hasPrefix("You're on the Darkbloom Sandbox waitlist: #2 in line.\n"))
        #expect(output.contains("  Nothing was installed. Run `\(Sandbox.cli) sandbox setup` again once Darkbloom approves your account.\n"))
        #expect(!output.contains("Checking this Mac"))
        #expect(output.hasSuffix("requests 0\n"))
        let revoked = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           waitlist: .answering(FeatureWaitlistTests.sandbox(.revoked))).run()
            }
        }
        #expect(decodedText(revoked.standardOutputContent).hasPrefix("Darkbloom revoked your account's access to Darkbloom Sandbox.\n"))
    }

    @Test("an account not on the waitlist joins it with --yes, or is told how without a terminal")
    func gateJoins() async throws {
        let joined = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           waitlist: .answering(FeatureWaitlistTests.sandbox(.none),
                                                                joined: FeatureWaitlistTests.sandbox(.waitlisted, position: 7))).run()
            }
        }
        let output = decodedText(joined.standardOutputContent)
        #expect(output.hasPrefix("Darkbloom Sandbox is open to the accounts Darkbloom approves from its waitlist.\njoined 1\n"
            + "You're on the Darkbloom Sandbox waitlist: #7 in line.\n"))
        #expect(!output.contains("Checking this Mac"))
        let unattended = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: false, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           waitlist: .answering(FeatureWaitlistTests.sandbox(.none))).run()
            }
        }
        #expect(decodedText(unattended.standardOutputContent) == "Darkbloom Sandbox is open to the accounts Darkbloom approves "
            + "from its waitlist.\n  Join it: \(Sandbox.cli) waitlist sandbox join\n")
        let approvedOnJoin = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            try replaceStandardInput(with: "y\n")
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: false, addon: .live(), interactiveInput: true,
                                           terminal: false, color: false,
                                           probe: { _ in .mac(cores: 8, memoryGiB: 16) },
                                           waitlist: .answering(FeatureWaitlistTests.sandbox(.none),
                                                                joined: FeatureWaitlistTests.sandbox(.approved))).run()
            }
        }
        // An account an admin already approved goes straight on to the checks.
        #expect(decodedText(approvedOnJoin.standardOutputContent).contains(
            "Join the Darkbloom Sandbox waitlist now? [y/N]: joined 1\nDarkbloom Sandbox setup\n\nChecking this Mac\n"))
    }

    @Test("without a login the gate says how to link this Mac")
    func gateNeedsLogin() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false, waitlist: .answering(.needsLogin)).run()
            }
        }
        #expect(decodedText(result.standardErrorContent).contains("Link this Mac to your Darkbloom account first: \(Sandbox.cli) login"))
    }
}
