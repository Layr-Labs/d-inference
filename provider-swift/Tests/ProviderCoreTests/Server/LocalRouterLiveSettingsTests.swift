import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
import notify
@testable import ProviderCore

/// A running local API uses a saved route and account key from its next request: `darkbloom route <choice>` and
/// `darkbloom route key` need no restart, so no model reloads for a routing change. The route is read again from the
/// provider config file when it changes; a file that doesn't read keeps the last good route and says so once. A
/// request this Mac serves never looks at the file. The races are pinned too: an edit while a request is passed on or
/// while the file is read, two quick edits, and an edit in place. Every test uses a temporary provider.toml, and the
/// router runs over a stub engine and coordinator; nothing leaves the process.
@Suite("Local router: saved route and key, live")
struct LocalRouterLiveSettingsTests {
    /// A provider.toml in its own temporary folder, replaced as `setLocalSettings` replaces it (a new file each time).
    final class ConfigFile: Sendable {
        let folder: URL
        let url: URL

        init(_ text: String) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("router-live-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            url = folder.appendingPathComponent("provider.toml")
            try write(text)
        }

        convenience init(route: LocalSettings.Route) throws { try self.init(Self.text(route)) }

        static func text(_ route: LocalSettings.Route) -> String {
            "[provider]\nname = \"router-live\"\n\n[local]\nmode = \"both\"\nroute = \"\(route.rawValue)\"\n"
        }

        func write(_ text: String) throws { try text.write(to: url, atomically: true, encoding: .utf8) }
        func save(_ route: LocalSettings.Route) throws { try write(Self.text(route)) }

        /// Rewrites the file where it is, as an editor that saves in place does: the same inode.
        func writeInPlace(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(text.utf8))
        }

        /// What `stat` says of the file now.
        var info: stat {
            var info = stat()
            _ = stat(url.path, &info)
            return info
        }

        /// Sets the file's modification time, to the nanosecond.
        func setModified(_ time: timespec) throws {
            var times = [time, time]
            guard utimensat(AT_FDCWD, url.path, &times, 0) == 0 else { throw POSIXError(.EIO) }
        }

        deinit { try? FileManager.default.removeItem(at: folder) }
    }

    /// One chat for `model`; returns its status and the route the coordinator was asked with (nil: not passed on).
    static func chat(_ client: some TestClientProtocol, _ model: String = "absent", upstream: RouterStubUpstream)
        async throws -> (HTTPResponse.Status, String?) {
        let before = upstream.posts.count
        var status = HTTPResponse.Status.ok
        try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                 body: ByteBuffer(string: RouterFixture.chat(model))) { response in
            status = response.status
        }
        return (status, upstream.posts.count > before ? upstream.posts.last?.route : nil)
    }

    @Test func aSavedRouteIsUsedOnTheNextRequestWithNoRestart() async throws {
        let file = try ConfigFile(route: .thisMac)
        let fixture = RouterFixture(route: .thisMac, settingsFile: file.url)
        try await fixture.app.test(.router) { client in
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.notFound, nil))
            try file.save(.myMacs)
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "self"))
            try file.save(.myMacsFirst)
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "prefer"))
            try file.save(.thisMac)
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.notFound, nil))
        }
        #expect(fixture.log.lines.contains("route is now my-macs (provider.toml changed)"))
        #expect(fixture.log.lines.contains("route is now my-macs-first (provider.toml changed)"))
        #expect(fixture.log.lines.contains("route is now this-mac (provider.toml changed)"))
        // One line per change: the first read finds the route the router started with, and says nothing.
        #expect(fixture.log.lines.filter { $0.hasPrefix("route is now") }.count == 3, "\(fixture.log.lines)")
    }

    @Test func theModelListFollowsTheSavedRouteToo() async throws {
        let file = try ConfigFile(route: .myMacs)
        let fixture = RouterFixture(route: .myMacs, settingsFile: file.url) { request in
            request.method == "GET" && request.url.path == "/v1/models" && request.route == nil
                ? .json(200, #"{"object":"list","data":[{"id":"big","owned_by":"darkbloom"}]}"#)
                : .json(200, #"{"object":"list","data":[]}"#)
        }
        try await fixture.app.test(.router) { client in
            #expect(try await !Self.networkListed(client))
            try file.save(.myMacsFirst)
            #expect(try await Self.networkListed(client))
        }
    }

    /// Whether the local `/v1/models` lists a network model.
    static func networkListed(_ client: some TestClientProtocol) async throws -> Bool {
        var listed = false
        try await client.execute(uri: "/v1/models", method: .get, headers: RouterFixture.authorized) { response in
            let list = try JSONDecoder().decode(LocalRouterModelList.self, from: Data(buffer: response.body))
            listed = list.data.contains { $0.ownedBy == "darkbloom" }
        }
        return listed
    }

    /// The key was already read again after `route key`'s notification; with the route read from the file, a key saved
    /// while the route is `my-macs` passes the next request on, and a key removed keeps the next one on this Mac.
    @Test func aKeySavedOrRemovedWhileRunningCountsFromTheNextRequest() async throws {
        let file = try ConfigFile(route: .myMacs)
        let fixture = RouterFixture(route: .myMacs, settingsFile: file.url, key: nil)
        let router = try #require(fixture.routerConfig)
        let notification = try #require(router.keyChangeNotification)
        try await fixture.app.test(.router) { client in
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.notFound, nil))
            try fixture.keys.save(RouterFixture.accountKey)
            notify_post(notification)
            #expect(await holdsWithinTwoSeconds { !router.keyCache.keepsACopy })
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "self"))
            try fixture.keys.remove()
            notify_post(notification)
            #expect(await holdsWithinTwoSeconds { !router.keyCache.keepsACopy })
            // This Mac's 404, served by this Mac, saying that your other Macs need a key (`LocalRouterMissingKeyTests`).
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: RouterFixture.authorized,
                                     body: ByteBuffer(string: RouterFixture.chat("absent"))) { response in
                #expect(response.status == .notFound)
                #expect(response.headers[LocalRouterPolicy.servedByHeader] == "this-mac")
                #expect(String(buffer: response.body).contains("account_key_needed"))
            }
        }
        #expect(fixture.upstream.posts.map(\.route) == ["self"])
        #expect(!fixture.log.lines.joined(separator: "\n").contains(RouterFixture.accountKey))
    }

    @Test func aMalformedEditKeepsTheLastGoodRouteAndSaysSoOnce() async throws {
        let file = try ConfigFile(route: .myMacs)
        let fixture = RouterFixture(route: .myMacs, settingsFile: file.url)
        let kept = "provider.toml doesn't read as a provider config now; requests keep the route my-macs until it does"
        try await fixture.app.test(.router) { client in
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "self"))
            try file.write("[local]\nmode = \"both\"\nroute = \"everywhere\"\n")
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "self"))
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "self"))
            try file.write("[local\nroute = ")
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "self"))
            #expect(fixture.log.lines.filter { $0 == kept }.count == 1, "\(fixture.log.lines)")
            try file.save(.myMacsFirst)
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "prefer"))
        }
        #expect(fixture.log.lines.contains("route is now my-macs-first (provider.toml changed)"))
        #expect(!fixture.log.lines.joined(separator: "\n").contains("everywhere"))
    }

    @Test func aRequestThisMacServesNeverLooksAtTheFile() async throws {
        let file = try ConfigFile(route: .myMacs)
        let fixture = RouterFixture(route: .myMacs, settingsFile: file.url)
        let router = try #require(fixture.routerConfig)
        try await fixture.app.test(.router) { client in
            for _ in 0..<5 { #expect(try await Self.chat(client, "here", upstream: fixture.upstream) == (.ok, nil)) }
            #expect(router.routeFile.checks == 0)
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.ok, "self"))
            #expect(router.routeFile.checks == 1)
            try await client.execute(uri: "/v1/models", method: .get, headers: RouterFixture.authorized) { response in
                #expect(response.status == .ok)
            }
            #expect(router.routeFile.checks == 2)
        }
    }

    /// `--no-auth`: nothing is passed on, so neither a request nor a model list looks at the file.
    @Test func withoutALocalKeyTheFileIsNeverLookedAt() async throws {
        let file = try ConfigFile(route: .myMacsFirst)
        let fixture = RouterFixture(route: .myMacsFirst, settingsFile: file.url, localKey: nil)
        let router = try #require(fixture.routerConfig)
        try await fixture.app.test(.router) { client in
            #expect(try await Self.chat(client, upstream: fixture.upstream) == (.notFound, nil))
            try await client.execute(uri: "/v1/models", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(router.routeFile.checks == 0)
        #expect(fixture.upstream.requests.isEmpty)
    }

    /// An edit while a request is passed on counts from the next request: the one in flight keeps its route through
    /// every hop (`prefer`, then `self` after the network's 402).
    @Test func anEditWhileARequestIsPassedOnCountsFromTheNextOne() async throws {
        let file = try ConfigFile(route: .myMacsFirst)
        let fixture = RouterFixture(route: .myMacsFirst, settingsFile: file.url) { request in
            guard request.method == "POST" else { return .json(200, #"{"object":"list","data":[]}"#) }
            guard request.route == "prefer" else {
                return .json(200, #"{"id":"chatcmpl-up","object":"chat.completion","choices":[]}"#)
            }
            try file.save(.thisMac)
            return .json(402, #"{"error":{"type":"insufficient_funds","message":"no balance"}}"#)
        }
        try await fixture.app.test(.router) { client in
            let passedOn = try await Self.chat(client, upstream: fixture.upstream)
            #expect(passedOn == (.ok, "self"))
            let next = try await Self.chat(client, upstream: fixture.upstream)
            #expect(next == (.notFound, nil))
        }
        #expect(fixture.upstream.posts.map(\.route) == ["prefer", "self"])
        #expect(fixture.log.lines.contains("route is now this-mac (provider.toml changed)"))
    }

    /// A client on another machine never takes the paid network, whichever route the file comes to say.
    @Test func aClientOnAnotherMachineStaysOffThePaidNetworkAfterAnEdit() async throws {
        let file = try ConfigFile(route: .myMacs)
        let fixture = RouterFixture(route: .myMacs, settingsFile: file.url) { request in
            request.method == "GET" ? .json(200, #"{"object":"list","data":[]}"#)
                : .json(200, #"{"id":"chatcmpl-up","object":"chat.completion","choices":[]}"#)
        }
        try file.save(.myMacsFirst)
        for (peer, routeUsed) in [("192.168.1.20", "self"), ("2001:db8::20", "self"), ("127.0.0.1", "prefer")] {
            let answer = try await LocalRouterRemoteClientTests.respond(
                fixture, peer: peer, method: .post, path: "/v1/chat/completions", body: RouterFixture.chat("elsewhere"))
            #expect(answer.status == .ok, "\(peer)")
            #expect(answer.routeUsed == routeUsed, "\(peer)")
        }
        #expect(fixture.upstream.posts.map(\.route) == ["self", "self", "prefer"])
    }

    /// The file is read again only when it changed (one `stat` a call otherwise); a file that is gone keeps the last
    /// good route and is said once; one that comes back is read again.
    @Test func theFileIsReadAgainOnlyWhenItChanges() throws {
        let file = try ConfigFile(route: .myMacs)
        let routes = LocalRouterRouteFile()
        let reads = RouterLogLines(), log = RouterLogLines()
        func route() -> LocalSettings.Route? {
            routes.route(in: file.url, startingWith: .thisMac, log: { log.append($0) }, read: { url in
                reads.append(url.lastPathComponent)
                return try Data(contentsOf: url)
            })
        }
        #expect(route() == .myMacs)
        #expect(route() == .myMacs)
        #expect(reads.lines.count == 1)
        try file.save(.myMacsFirst)
        #expect(route() == .myMacsFirst)
        #expect(reads.lines.count == 2)
        try FileManager.default.removeItem(at: file.url)
        #expect(route() == .myMacsFirst)
        #expect(route() == .myMacsFirst)
        #expect(log.lines.filter { $0.hasPrefix("provider.toml doesn't read") }.count == 1)
        try file.save(.thisMac)
        #expect(route() == .thisMac)
        #expect(routes.checks == 6)
        #expect(reads.lines.count == 4)
    }

    /// The `stat` comes before the read: an edit that lands while the file is read is read again by the next call.
    @Test func anEditDuringTheReadIsReadByTheNextCall() throws {
        let file = try ConfigFile(route: .myMacs)
        let routes = LocalRouterRouteFile()
        var editsDuringTheRead = 1
        func route() -> LocalSettings.Route? {
            routes.route(in: file.url, startingWith: .thisMac, log: { _ in }, read: { url in
                let bytes = try Data(contentsOf: url)
                if editsDuringTheRead > 0 {
                    editsDuringTheRead -= 1
                    try file.save(.myMacsFirst)
                }
                return bytes
            })
        }
        #expect(route() == .myMacs)
        #expect(route() == .myMacsFirst)
        #expect(route() == .myMacsFirst)
    }

    /// Two edits between requests: the next one reads the file once, as the second left it.
    @Test func twoQuickEditsAreReadOnceAsTheLastLeftIt() throws {
        let file = try ConfigFile(route: .myMacs)
        let routes = LocalRouterRouteFile()
        let reads = RouterLogLines(), log = RouterLogLines()
        func route() -> LocalSettings.Route? {
            routes.route(in: file.url, startingWith: .myMacs, log: { log.append($0) }, read: { url in
                reads.append(url.lastPathComponent)
                return try Data(contentsOf: url)
            })
        }
        #expect(route() == .myMacs)
        try file.save(.myMacsFirst)
        try file.save(.thisMac)
        #expect(route() == .thisMac)
        #expect(reads.lines.count == 2)
        #expect(log.lines == ["route is now this-mac (provider.toml changed)"])
    }

    /// An edit in place keeps the inode: its new size tells it apart, and at the same size its modification time does,
    /// to the nanosecond.
    @Test func anEditInPlaceIsReadToo() throws {
        let file = try ConfigFile(route: .myMacs)
        let routes = LocalRouterRouteFile()
        func route() -> LocalSettings.Route? { routes.route(in: file.url, startingWith: .thisMac, log: { _ in }) }
        let first = file.info
        #expect(route() == .myMacs)
        // Another size, with the first modification time put back: only the size differs.
        try file.writeInPlace(ConfigFile.text(.myMacsFirst))
        try file.setModified(first.st_mtimespec)
        #expect(file.info.st_size != first.st_size)
        #expect(route() == .myMacsFirst)
        // "my-macs" padded to the length of "my-macs-first", one nanosecond later: only the modification time differs.
        let sameSize = ConfigFile.text(.myMacs).replacingOccurrences(of: "\"my-macs\"", with: "\"my-macs\"      ")
        try file.writeInPlace(sameSize)
        var later = first.st_mtimespec
        later.tv_nsec = (later.tv_nsec + 1) % 1_000_000_000
        try file.setModified(later)
        #expect(file.info.st_size == ConfigFile.text(.myMacsFirst).utf8.count)
        #expect(file.info.st_mtimespec.tv_sec == first.st_mtimespec.tv_sec)
        #expect(route() == .myMacs)
        #expect(file.info.st_ino == first.st_ino)
    }

    /// Each run of bad reads is said once: after a good read, the next bad one is said again.
    @Test func eachRunOfBadReadsIsSaidOnce() throws {
        let file = try ConfigFile(route: .myMacs)
        let routes = LocalRouterRouteFile()
        let log = RouterLogLines()
        func route() -> LocalSettings.Route? {
            routes.route(in: file.url, startingWith: .myMacs, log: { log.append($0) })
        }
        #expect(route() == .myMacs)
        try file.write("[local\nroute = ")
        #expect(route() == .myMacs)
        try file.write("[local]\nroute = \"everywhere\"\n")
        #expect(route() == .myMacs)
        try file.save(.myMacsFirst)
        #expect(route() == .myMacsFirst)
        try file.write("[local\n")
        #expect(route() == .myMacsFirst)
        #expect(log.lines == [
            "provider.toml doesn't read as a provider config now; requests keep the route my-macs until it does",
            "route is now my-macs-first (provider.toml changed)",
            "provider.toml doesn't read as a provider config now; requests keep the route my-macs-first until it does",
        ])
    }

    // MARK: - A save in place

    /// An editor that saves in place empties the file, then writes it. A request that finds it empty keeps the last good
    /// route: with `this-mac` saved and a key, nothing is passed on (an empty file read as "no route" would mean
    /// `my-macs`). Said once, and the whole file then reads as before, with no "route is now" line.
    @Test func aFileFoundEmptyWhileItIsSavedInPlaceKeepsTheLastGoodRoute() async throws {
        let file = try ConfigFile(route: .thisMac)
        let fixture = RouterFixture(route: .thisMac, settingsFile: file.url)
        try await fixture.app.test(.router) { client in
            let before = try await Self.chat(client, upstream: fixture.upstream)
            #expect(before == (.notFound, nil))
            try file.writeInPlace("")
            let midSave = try await Self.chat(client, upstream: fixture.upstream)
            #expect(midSave == (.notFound, nil))
            try file.writeInPlace(ConfigFile.text(.thisMac))
            let after = try await Self.chat(client, upstream: fixture.upstream)
            #expect(after == (.notFound, nil))
        }
        #expect(fixture.upstream.posts.count == 0)
        #expect(fixture.log.lines == [
            "provider.toml doesn't read as a provider config now; requests keep the route this-mac until it does",
        ])
    }

    /// A read that catches a save in place half done keeps the last good route: the `stat` saw the whole file, and the
    /// read finds it emptied, or holding only its start (which parses, without `[local] route`). The next call reads
    /// the file whole.
    @Test func aReadThatCatchesASaveInPlaceHalfDoneKeepsTheLastGoodRoute() throws {
        let whole = ConfigFile.text(.thisMac)
        let start = try #require(whole.components(separatedBy: "route = ").first)
        for midSave in ["", start] {
            let file = try ConfigFile(whole)
            let routes = LocalRouterRouteFile()
            var pending: String? = midSave
            func route() -> LocalSettings.Route? {
                routes.route(in: file.url, startingWith: .thisMac, log: { _ in }, read: { url in
                    if let text = pending {
                        pending = nil
                        try file.writeInPlace(text)
                    }
                    return try Data(contentsOf: url)
                })
            }
            #expect(route() == .thisMac, "\(midSave.debugDescription)")
            try file.writeInPlace(whole)
            #expect(route() == .thisMac, "\(midSave.debugDescription)")
        }
    }

    /// `this-mac` saved in place over and over while requests this Mac can't take keep coming: not one is passed on.
    @Test func aThisMacFileSavedInPlaceOverAndOverPassesNothingOn() async throws {
        let file = try ConfigFile(route: .thisMac)
        let fixture = RouterFixture(route: .thisMac, settingsFile: file.url)
        let saving = SavingInPlace(file, text: ConfigFile.text(.thisMac))
        try await fixture.app.test(.router) { client in
            for _ in 0..<2_000 { _ = try await Self.chat(client, upstream: fixture.upstream) }
        }
        let saves = await saving.stop()
        let passedOn = fixture.upstream.posts.count
        #expect(saves > 100, "the file was saved only \(saves) times")
        #expect(passedOn == 0, "\(passedOn) of 2,000 requests were passed on")
        #expect(!fixture.log.lines.contains { $0.hasPrefix("route is now") }, "\(Set(fixture.log.lines))")
    }

    /// Saves `text` into `file` in place, over and over, from its own task until `stop()`, which returns how many times.
    final class SavingInPlace: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        private var task: Task<Int, Never>?

        init(_ file: ConfigFile, text: String) {
            task = Task.detached { [self] in
                var saves = 0
                while !isStopped {
                    try? file.writeInPlace(text)
                    saves += 1
                }
                return saves
            }
        }

        private var isStopped: Bool { lock.withLock { stopped } }

        func stop() async -> Int {
            lock.withLock { stopped = true }
            return await task?.value ?? 0
        }
    }
}
