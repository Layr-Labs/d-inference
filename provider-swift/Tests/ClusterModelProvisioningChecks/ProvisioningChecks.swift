import Foundation
import Darwin
import CryptoKit

/// Model-free checks of cluster model provisioning (built with plain swiftc by run.sh): the manifest checks, the
/// copy-or-download decision for 2-4 Macs, and the receiver end to end on temporary folders.
@main enum ProvisioningChecks {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failures = [String]()

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        if condition { passed += 1 } else { failures.append("line \(line): \(message())") }
    }

    static func refuses(_ needle: String, line: Int = #line, _ body: () throws -> Void) {
        do { try body(); expect(false, "expected a refusal containing \"\(needle)\"", line: line) } catch {
            expect("\(error)".contains(needle), "refusal \"\(error)\" should contain \"\(needle)\"", line: line)
        }
    }

    static func main() {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(120); defer { alarm(0) }
        manifestChecks()
        decisionChecks()
        copyEndToEnd()
        digestMismatchRefused()
        hardLinkRefused()
        insufficientDiskRefused()
        resumeAfterInterruption()
        destinationOccupiedRefused()
        catalogIdentityChecked()
        wireRoundTrip()
        // Review 2026-10-13 (adversarial): failing first on d2859ce60.
        onlyPinnedArtifactsAccepted()
        sameFilesOtherCatalogEntryIsNotHeld()
        concurrentClonesNeverMix()
        commitNeverReplacesAFolder()
        abandonedStagingReclaimedForSpace()
        // Finish 2026-10-13 night: failing first on c35897c36.
        renamedFilesAreNotTheArtifact()
        stagedCheckRefusesRenamedCopy()
        diskFilledDuringCopyStopsCleanly()
        shortCopiesAreNotAskedFor()
        // Finish review 2026-10-13 night: failing first on 754286da9.
        stagingHoldsOnlyTheManifestFiles()
        print("provisioning checks: \(passed) passed, \(failures.count) failed")
        for failure in failures { print("FAIL " + failure) }
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - Fixtures

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A small model: a config, a tokenizer and two weight shards (one larger than a chunk), with its manifest.
    static func fixture(modelID: String = "Example/Tiny-Model", version: String = "2026-10-13-r1")
        -> (files: [(String, Data)], manifest: Data, artifact: ClusterCatalogArtifact) {
        var generator = SystemRandomNumberGenerator()
        func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }) }
        let files: [(String, Data)] = [("config.json", Data("{\"num_hidden_layers\":2}".utf8)), ("tokenizer.json", random(3000)),
                                       ("model-00001-of-00002.safetensors", random(3 << 20)), ("model-00002-of-00002.safetensors", random(70_000))]
        let entries = files.map { ["path": $0.0, "size_bytes": $0.1.count, "sha256": sha($0.1), "role": "weight"] as [String: Any] }
        let artifactFiles = files.map { ClusterCatalogArtifact.File(path: $0.0, sizeBytes: Int64($0.1.count), sha256: sha($0.1)) }
        let object: [String: Any] = ["schema_version": 1, "model_id": modelID, "version": version, "r2_prefix": "v2/x/\(version)",
            "aggregate_sha256": ClusterCatalogArtifact.aggregateDigest(artifactFiles), "total_size_bytes": files.reduce(0) { $0 + $1.1.count },
            "file_count": files.count, "files": entries, "created_at": "2026-10-13T00:00:00Z"]
        let manifest = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return (files, manifest, try! ClusterCatalogArtifact.parse(manifest: manifest))
    }

    static func temporary(_ name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prov-\(name)-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func source(_ fixture: (files: [(String, Data)], manifest: Data, artifact: ClusterCatalogArtifact)) -> URL {
        let directory = temporary("source").appendingPathComponent(fixture.artifact.folderName)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, data) in fixture.files {
            let url = directory.appendingPathComponent(path)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! data.write(to: url)
        }
        try! fixture.manifest.write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }

    /// Sends every file from its resume offset in 1 MiB chunks, as the leader does over the link.
    static func send(_ sender: ClusterModelSender, to receiver: ClusterModelReceiver, from offsets: [Int64], stopAfterBytes: Int64? = nil) throws -> Bool {
        var sent: Int64 = 0
        for (index, file) in sender.artifact.files.enumerated() {
            var offset = offsets[index]
            if offset == file.sizeBytes { continue }
            while offset < file.sizeBytes {
                let bytes = try sender.read(index: index, offset: offset, count: 1 << 20)
                let frame = ClusterModelTransferWire.chunk(index: index, offset: offset, bytes)
                guard let parsed = ClusterModelTransferWire.parseChunk(frame) else { throw ClusterModelProvisioningError("frame") }
                try receiver.write(index: parsed.index, offset: parsed.offset, parsed.bytes)
                offset += Int64(bytes.count); sent += Int64(bytes.count)
                if let stop = stopAfterBytes, sent >= stop { return false }
            }
            try receiver.finish(index: index)
        }
        return true
    }

    // MARK: - Manifest

    static func manifestChecks() {
        let model = fixture()
        expect(model.artifact.files.count == 4 && model.artifact.totalBytes == Int64(model.files.reduce(0) { $0 + $1.1.count }), "manifest parsed")
        expect(model.artifact.folderName == "Tiny-Model-2026-10-13-r1", "folder: the model ID's last part and the version, got \(model.artifact.folderName)")
        // The CDN lists the files in another order than the receipt (2026-10-15): the same files in any order match.
        let files = model.artifact.files
        expect(ClusterCatalogArtifact.sameFiles(files, files.reversed()), "the same files in another order match")
        expect(!ClusterCatalogArtifact.sameFiles(files, Array(files.dropLast())), "a missing file does not match")
        var changed = files; changed[0].sha256 = String(repeating: "0", count: 64)
        expect(!ClusterCatalogArtifact.sameFiles(files, changed), "a different digest does not match")
        // Dropping a folder's cached pages: every regular file, nothing else, the bytes unchanged (2026-10-16).
        let cacheFolder = temporary("drop-cache")
        try! FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        try! Data(repeating: 7, count: 1 << 20).write(to: cacheFolder.appendingPathComponent("weights.safetensors"))
        try! Data("{}".utf8).write(to: cacheFolder.appendingPathComponent("config.json"))
        try! FileManager.default.createDirectory(at: cacheFolder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        expect(ClusterModelStore.dropCachedPages(folder: cacheFolder) == Int64((1 << 20) + 2), "every regular file's pages dropped")
        expect((try? Data(contentsOf: cacheFolder.appendingPathComponent("weights.safetensors")))?.count == 1 << 20, "the bytes unchanged")
        expect(ClusterModelStore.dropCachedPages(folder: cacheFolder.appendingPathComponent("missing")) == 0, "a missing folder drops nothing")
        // Reading a folder's pages into the cache before a part starts: every regular file once, no link, no folder.
        try! FileManager.default.createSymbolicLink(at: cacheFolder.appendingPathComponent("link.safetensors"),
            withDestinationURL: cacheFolder.appendingPathComponent("weights.safetensors"))
        expect(ClusterModelStore.prefetchPages(folder: cacheFolder) == Int64((1 << 20) + 2), "every regular file's pages read once")
        expect(ClusterModelStore.prefetchPages(folder: cacheFolder, readers: 1) == Int64((1 << 20) + 2), "one reader reads the same")
        expect(ClusterModelStore.prefetchPages(folder: cacheFolder.appendingPathComponent("missing")) == 0, "a missing folder reads nothing")
        func mutated(_ change: (inout [String: Any]) -> Void) -> Data {
            var object = try! JSONSerialization.jsonObject(with: model.manifest) as! [String: Any]
            change(&object)
            return try! JSONSerialization.data(withJSONObject: object)
        }
        refuses("aggregate") { _ = try ClusterCatalogArtifact.parse(manifest: mutated { $0["aggregate_sha256"] = String(repeating: "a", count: 64) }) }
        refuses("aggregate") { _ = try ClusterCatalogArtifact.parse(manifest: mutated {
            var files = $0["files"] as! [[String: Any]]; files[1]["sha256"] = String(repeating: "b", count: 64); $0["files"] = files }) }
        refuses("unsafe") { _ = try ClusterCatalogArtifact.parse(manifest: mutated {
            var files = $0["files"] as! [[String: Any]]; files[0]["path"] = "../../etc/passwd"; $0["files"] = files }) }
        refuses("unsafe") { _ = try ClusterCatalogArtifact.parse(manifest: mutated {
            var files = $0["files"] as! [[String: Any]]; files[0]["path"] = ".darkbloom-manifest.json"; $0["files"] = files }) }
        refuses("unsafe") { _ = try ClusterCatalogArtifact.parse(manifest: mutated {
            var files = $0["files"] as! [[String: Any]]; files[0]["path"] = "/abs/config.json"; $0["files"] = files }) }
        refuses("unsafe, duplicate") { _ = try ClusterCatalogArtifact.parse(manifest: mutated {
            var files = $0["files"] as! [[String: Any]]; files[1]["path"] = "CONFIG.JSON"; $0["files"] = files }) }
        refuses("total") { _ = try ClusterCatalogArtifact.parse(manifest: mutated { $0["total_size_bytes"] = 1 }) }
        refuses("file count") { _ = try ClusterCatalogArtifact.parse(manifest: mutated { $0["file_count"] = 9 }) }
        refuses("identity") { _ = try ClusterCatalogArtifact.parse(manifest: mutated { $0["model_id"] = nil }) }
        refuses("cannot be read") { _ = try ClusterCatalogArtifact.parse(manifest: Data("not json".utf8)) }
        expect(ClusterCatalogArtifact.safeFolder("Qwen3.5-9B-2026-09-03-r1") != nil, "a catalog folder name is safe")
        expect(ClusterCatalogArtifact.safeFolder("a/b") == nil && ClusterCatalogArtifact.safeFolder(".hidden") == nil
            && ClusterCatalogArtifact.safeFolder("..") == nil, "nested, hidden and parent names are not")
    }

    // MARK: - Copy or download

    static func decisionChecks() {
        typealias P = ClusterModelProvisioning
        typealias Mac = ClusterModelProvisioningMac
        let size: Int64 = 6_113_952_230
        let tb = 2.5e9
        // Leader has it, member lacks it: copy over the cable, by default.
        var plan = P.plan(totalBytes: size, leader: Mac(name: "M3 Ultra", holding: .complete(folder: "m"), freeBytes: 500e9.int),
            members: [Mac(name: "M5 Ultra", holding: .missing, freeBytes: 500e9.int)], linkBytesPerSecond: tb, catalogHasIt: true)
        expect(plan.steps.map(\.source) == [.present, .copy(from: "M3 Ultra")], "leader has it: the member copies it from the leader \(plan.steps)")
        expect(P.lines(plan) == ["M5 Ultra: copy from M3 Ultra over the Thunderbolt cable (6.1 GB, about 2 s)"], "copy line with size and ETA: \(P.lines(plan))")
        expect(plan.blocker == nil && !plan.ready, "copy plan can start")
        // The person prefers the catalog for the member.
        plan = P.plan(totalBytes: size, leader: Mac(name: "A", holding: .complete(folder: "m"), freeBytes: nil),
            members: [Mac(name: "B", holding: .missing, freeBytes: nil)], linkBytesPerSecond: tb, catalogHasIt: true, preferDownload: true)
        expect(plan.steps.map(\.source) == [.present, .download], "download chosen instead of the cable when asked")
        // Nobody has it: the leader downloads, every member copies from the leader.
        plan = P.plan(totalBytes: size, leader: Mac(name: "A", holding: .missing, freeBytes: nil),
            members: [Mac(name: "B", holding: .missing, freeBytes: nil), Mac(name: "C", holding: .missing, freeBytes: nil)],
            linkBytesPerSecond: nil, catalogHasIt: true)
        expect(plan.steps.map(\.source) == [.download, .copy(from: "A"), .copy(from: "A")], "no Mac has it: leader downloads, members copy \(plan.steps)")
        expect(P.lines(plan).first == "A: download from Darkbloom's catalog (6.1 GB)", "no estimate without a measured rate: \(P.lines(plan))")
        // Not in the catalog and no Mac has it: blocked.
        plan = P.plan(totalBytes: size, leader: Mac(name: "A", holding: .missing, freeBytes: nil), members: [Mac(name: "B", holding: .missing, freeBytes: nil)],
            linkBytesPerSecond: tb, catalogHasIt: false)
        expect(plan.blocker == "no Mac has it and the catalog does not offer it", "nothing to fetch from: \(String(describing: plan.blocker))")
        // A member has it and the leader does not: the leader copies from that member, the others copy from it too.
        plan = P.plan(totalBytes: size, leader: Mac(name: "A", holding: .missing, freeBytes: nil),
            members: [Mac(name: "B", holding: .missing, freeBytes: nil), Mac(name: "C", holding: .complete(folder: "m"), freeBytes: nil),
                      Mac(name: "D", holding: .missing, freeBytes: nil)], linkBytesPerSecond: tb, catalogHasIt: true)
        expect(plan.steps.map(\.source) == [.copy(from: "C"), .copy(from: "C"), .present, .copy(from: "C")], "a member holds it: copies come from it \(plan.steps)")
        // Everyone has it: nothing moves.
        plan = P.plan(totalBytes: size, leader: Mac(name: "A", holding: .complete(folder: "m"), freeBytes: nil),
            members: [Mac(name: "B", holding: .complete(folder: "m"), freeBytes: nil)], linkBytesPerSecond: tb, catalogHasIt: true)
        expect(plan.ready && P.lines(plan).isEmpty, "every Mac has it: ready, nothing to say")
        // A download and a copy are asked for once: the prompt carries the total size and, when every rate is known, the time.
        let both = P.plan(totalBytes: 6_100_000_000, leader: .init(name: "A", holding: .missing, freeBytes: nil),
            members: [.init(name: "B", holding: .missing, freeBytes: nil)], linkBytesPerSecond: 3e9, downloadBytesPerSecond: 1e8, catalogHasIt: true)
        expect(P.lines(both).last == "In all: 12.2 GB, about 63 s", "the total of a download and a copy: \(P.lines(both))")
        let unknown = P.plan(totalBytes: 6_100_000_000, leader: .init(name: "A", holding: .missing, freeBytes: nil),
            members: [.init(name: "B", holding: .missing, freeBytes: nil)], linkBytesPerSecond: nil, catalogHasIt: true)
        expect(P.lines(unknown).last == "In all: 12.2 GB", "no time when a rate is not measured yet: \(P.lines(unknown))")
        // A resumed copy moves only what is left.
        plan = P.plan(totalBytes: size, leader: Mac(name: "A", holding: .complete(folder: "m"), freeBytes: nil),
            members: [Mac(name: "B", holding: .partial(bytes: size - 1_000_000_000), freeBytes: nil)], linkBytesPerSecond: 1e9, catalogHasIt: true)
        expect(plan.steps[1].bytes == 1_000_000_000 && P.lines(plan) == ["B: copy from A over the Thunderbolt cable (1.0 GB, about 1 s)"], "resume counts what is left: \(P.lines(plan))")
        // Not enough disk on the member: named with the numbers.
        plan = P.plan(totalBytes: size, leader: Mac(name: "A", holding: .complete(folder: "m"), freeBytes: nil),
            members: [Mac(name: "B", holding: .missing, freeBytes: 7_000_000_000)], linkBytesPerSecond: tb, catalogHasIt: true)
        expect(plan.blocker == "B has 7.0 GB free; the model needs 6.1 GB and 2.1 GB to spare", "disk blocker: \(String(describing: plan.blocker))")
        expect(P.duration(3) == "about 3 s" && P.duration(400) == "about 7 min" && P.duration(9000) == "about 2.5 h", "durations in words")
    }

    // MARK: - Receiver

    static func copyEndToEnd() {
        let model = fixture()
        let from = source(model)
        let store = temporary("store")
        do {
            let receiver = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: model.artifact.aggregateSHA256)
            let state = try receiver.begin()
            expect(!state.complete && state.offsets == [0, 0, 0, 0], "fresh store: nothing held \(state)")
            expect(ClusterModelStore.holding(store: store, artifact: model.artifact) == .missing, "nothing listed while staging is empty")
            let sender = try ClusterModelSender(artifact: model.artifact, directory: from)
            _ = try send(sender, to: receiver, from: state.offsets)
            expect(ClusterModelStore.holding(store: store, artifact: model.artifact) != .complete(folder: model.artifact.folderName),
                "the folder does not appear before the commit")
            let placed = try receiver.commit()
            expect(placed.lastPathComponent == model.artifact.folderName, "placed under the leader's folder name")
            for (path, data) in model.files {
                expect((try? Data(contentsOf: placed.appendingPathComponent(path))) == data, "\(path) copied byte for byte")
                var info = stat(); lstat(placed.appendingPathComponent(path).path, &info)
                expect(info.st_nlink == 1, "\(path) is single-linked")
            }
            expect((try? Data(contentsOf: placed.appendingPathComponent("manifest.json"))) == model.manifest, "the manifest is written as received")
            expect(ClusterModelStore.holding(store: store, artifact: model.artifact) == .complete(folder: model.artifact.folderName), "listed as complete by digest")
            let staging = store.appendingPathComponent(ClusterModelStore.stagingName(model.artifact))
            expect(!FileManager.default.fileExists(atPath: staging.path), "staging renamed away")
            // Again: the store already has it, nothing to send.
            let again = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil).begin()
            expect(again.complete, "a second copy finds the model complete")
        } catch { expect(false, "end to end: \(error)") }
    }

    static func digestMismatchRefused() {
        let model = fixture()
        let from = source(model)
        let store = temporary("store")
        // One byte changed on the sending side after the manifest was taken.
        let shard = from.appendingPathComponent("model-00001-of-00002.safetensors")
        var bytes = try! Data(contentsOf: shard); bytes[1234] ^= 0xFF; try! bytes.write(to: shard)
        do {
            let receiver = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil)
            let state = try receiver.begin()
            let sender = try ClusterModelSender(artifact: model.artifact, directory: from)
            refuses("does not match its manifest digest") { _ = try send(sender, to: receiver, from: state.offsets) }
            refuses("did not arrive") { _ = try receiver.commit() }
            let part = store.appendingPathComponent(ClusterModelStore.stagingName(model.artifact)).appendingPathComponent("model-00001-of-00002.safetensors.part")
            expect(!FileManager.default.fileExists(atPath: part.path), "the bad copy is discarded")
            expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent(model.artifact.folderName).path), "no folder appears")
        } catch { expect(false, "digest mismatch setup: \(error)") }
    }

    static func hardLinkRefused() {
        let model = fixture()
        let store = temporary("store")
        do {
            let receiver = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil)
            _ = try receiver.begin()
            // A staged file that is a hard link (another name could change it after verification).
            let staging = store.appendingPathComponent(ClusterModelStore.stagingName(model.artifact))
            let staged = staging.appendingPathComponent("config.json")
            try model.files[0].1.write(to: staged)
            let other = store.appendingPathComponent("elsewhere")
            expect(link(staged.path, other.path) == 0, "fixture hard link")
            refuses("single-linked") { _ = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil).begin() }
            _ = receiver
            // A complete copy whose staged file gains a second name before the commit: the folder never appears.
            let store2 = temporary("store2")
            let from = source(model)
            let r = try ClusterModelReceiver(artifact: model.artifact, store: store2, folder: model.artifact.folderName, expectedAggregate: nil)
            _ = try send(try ClusterModelSender(artifact: model.artifact, directory: from), to: r, from: try r.begin().offsets)
            let shard = store2.appendingPathComponent(ClusterModelStore.stagingName(model.artifact)).appendingPathComponent("tokenizer.json")
            expect(link(shard.path, store2.appendingPathComponent("second-name").path) == 0, "fixture hard link 2")
            refuses("single-linked") { _ = try r.commit() }
            expect(!FileManager.default.fileExists(atPath: store2.appendingPathComponent(model.artifact.folderName).path), "no folder with a hard-linked file")
        } catch { expect(false, "hard link setup: \(error)") }
    }

    static func insufficientDiskRefused() {
        let model = fixture()
        let store = temporary("store")
        refuses("free; the copy needs") {
            _ = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil,
                freeBytes: { _ in 1_000_000 }).begin()
        }
        expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent(model.artifact.folderName).path), "nothing placed")
        expect(ClusterModelStore.freeBytes(at: store).map { $0 > 0 } == true, "the real free-disk probe answers")
    }

    static func resumeAfterInterruption() {
        let model = fixture()
        let from = source(model)
        let store = temporary("store")
        do {
            let first = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil)
            let state = try first.begin()
            let sender = try ClusterModelSender(artifact: model.artifact, directory: from)
            // Interrupted 2 MiB into the copy: the config and tokenizer done, the first shard part-way.
            let finished = try send(sender, to: first, from: state.offsets, stopAfterBytes: 2 << 20)
            expect(!finished, "the copy was interrupted")
            if case .partial(let bytes) = ClusterModelStore.holding(store: store, artifact: model.artifact) {
                expect(bytes >= 2 << 20, "partial bytes are listed for the resume: \(bytes)")
            } else { expect(false, "an interrupted copy is listed as partial") }
            // A new process (the first one ended) resumes from what is staged.
            let second = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil)
            let resumed = try second.begin()
            expect(resumed.offsets[0] == model.artifact.files[0].sizeBytes && resumed.offsets[1] == model.artifact.files[1].sizeBytes,
                "verified files are not sent again: \(resumed.offsets)")
            expect(resumed.offsets[2] > 0 && resumed.offsets[2] < model.artifact.files[2].sizeBytes, "the shard resumes part-way: \(resumed.offsets)")
            expect(resumed.offsets[3] == 0, "the last file starts from zero")
            _ = try send(sender, to: second, from: resumed.offsets)
            let placed = try second.commit()
            for (path, data) in model.files { expect((try? Data(contentsOf: placed.appendingPathComponent(path))) == data, "resumed \(path) byte for byte") }
            // A resumed prefix that was tampered with is caught at the file's digest.
            let store2 = temporary("store2")
            let r1 = try ClusterModelReceiver(artifact: model.artifact, store: store2, folder: model.artifact.folderName, expectedAggregate: nil)
            _ = try send(sender, to: r1, from: try r1.begin().offsets, stopAfterBytes: 2 << 20)
            let part = store2.appendingPathComponent(ClusterModelStore.stagingName(model.artifact)).appendingPathComponent("model-00001-of-00002.safetensors.part")
            let handle = try FileHandle(forUpdating: part); try handle.seek(toOffset: 10); handle.write(Data([0x00, 0x01, 0x02])); try handle.close()
            let r2 = try ClusterModelReceiver(artifact: model.artifact, store: store2, folder: model.artifact.folderName, expectedAggregate: nil)
            refuses("does not match its manifest digest") { _ = try send(sender, to: r2, from: try r2.begin().offsets) }
        } catch { expect(false, "resume: \(error)") }
    }

    static func destinationOccupiedRefused() {
        let model = fixture()
        let store = temporary("store")
        try! FileManager.default.createDirectory(at: store.appendingPathComponent(model.artifact.folderName), withIntermediateDirectories: true)
        refuses("exists in this Mac's model store with other contents") {
            _ = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil).begin()
        }
        refuses("not safe") { _ = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: "../x", expectedAggregate: nil) }
    }

    static func catalogIdentityChecked() {
        let model = fixture()
        let store = temporary("store")
        refuses("not the catalog's Example/Tiny-Model 2026-10-13-r1") {
            _ = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName,
                expectedAggregate: String(repeating: "c", count: 64))
        }
        refuses("protected build") {
            _ = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil,
                trust: { _ in "a protected build: this Mac's catalog does not confirm it" })
        }
    }

    // MARK: - Review 2026-10-13

    /// The receiving Mac accepts only an artifact this build's own qualification records pin (the records are the
    /// only per-model data, and a pair serves nothing else): a paired peer cannot place a self-consistent manifest of
    /// arbitrary files, under any model name, in another Mac's store. Protected builds keep their own words.
    static func onlyPinnedArtifactsAccepted() {
        let model = fixture()
        let pinned: Set<String> = [model.artifact.aggregateSHA256]
        expect(ClusterModelCopyTrust.refusal(model.artifact, pinnedArtifacts: pinned, protected: false) == nil, "a pinned artifact is accepted")
        let forged = fixture(modelID: "mlx-community/Qwen3.5-9B")
        let refusal = ClusterModelCopyTrust.refusal(forged.artifact, pinnedArtifacts: pinned, protected: false)
        expect(refusal?.contains("qualification records do not pin") == true, "an unpinned artifact is refused before any byte: \(String(describing: refusal))")
        let protectedRefusal = ClusterModelCopyTrust.refusal(forged.artifact, pinnedArtifacts: pinned, protected: true)
        expect(protectedRefusal?.contains("protected build") == true, "a protected build keeps its words: \(String(describing: protectedRefusal))")
        expect(ClusterModelCopyTrust.refusal(forged.artifact, pinnedArtifacts: [], protected: false) != nil, "no records: nothing is accepted")
        let store = temporary("store")
        refuses("qualification records do not pin") {
            _ = try ClusterModelReceiver(artifact: forged.artifact, store: store, folder: forged.artifact.folderName, expectedAggregate: nil,
                trust: { ClusterModelCopyTrust.refusal($0, pinnedArtifacts: pinned, protected: false) })
        }
        expect(((try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []).isEmpty, "nothing is staged for a refused artifact")
    }

    /// Two catalog entries can share every file and so the aggregate digest (the catalog's gemma-4-26b and
    /// gemma-4-26b-8bit do; the runtime tells them apart by the manifest). A folder of one does not hold the other.
    static func sameFilesOtherCatalogEntryIsNotHeld() {
        let model = fixture()
        let twin = renamed(model, modelID: "Example/Tiny-Model-8bit")
        expect(twin.artifact.aggregateSHA256 == model.artifact.aggregateSHA256 && twin.manifest != model.manifest, "fixture: same files, other entry")
        let store = temporary("store")
        do {
            let receiver = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil)
            _ = try send(try ClusterModelSender(artifact: model.artifact, directory: source(model)), to: receiver, from: try receiver.begin().offsets)
            _ = try receiver.commit()
            expect(ClusterModelStore.holding(store: store, artifact: model.artifact) == .complete(folder: model.artifact.folderName), "its own entry is held")
            expect(ClusterModelStore.holding(store: store, artifact: twin.artifact) == .missing,
                "the other entry is not held by a folder of the first: \(ClusterModelStore.holding(store: store, artifact: twin.artifact))")
            expect(model.artifact.sameEntry(modelID: model.artifact.modelID, version: model.artifact.version, aggregate: model.artifact.aggregateSHA256)
                && !twin.artifact.sameEntry(modelID: model.artifact.modelID, version: model.artifact.version, aggregate: model.artifact.aggregateSHA256),
                "sameEntry compares the model, the version and the digest")
            let state = try ClusterModelReceiver(artifact: twin.artifact, store: store, folder: twin.artifact.folderName, expectedAggregate: nil).begin()
            expect(!state.complete, "the other entry is received into its own folder")
        } catch { expect(false, "same files, other entry: \(error)") }
    }

    static func renamed(_ model: (files: [(String, Data)], manifest: Data, artifact: ClusterCatalogArtifact), modelID: String)
        -> (files: [(String, Data)], manifest: Data, artifact: ClusterCatalogArtifact) {
        var object = try! JSONSerialization.jsonObject(with: model.manifest) as! [String: Any]
        object["model_id"] = modelID
        let manifest = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return (model.files, manifest, try! ClusterCatalogArtifact.parse(manifest: manifest))
    }

    /// The onboarding and the cluster service (two processes) may both clone a single-Mac model into the cluster
    /// store at once: one must never delete the other's staging, and the folder appears whole or not at all.
    static func concurrentClonesNeverMix() {
        let model = fixture()
        let from = source(model)
        let store = temporary("store")
        // Another process is part-way through the same clone (its staging under the shared name of d2859ce60).
        let theirs = store.appendingPathComponent(".darkbloom-clone-" + String(model.artifact.aggregateSHA256.prefix(32)))
        try! FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try! Data("in progress".utf8).write(to: theirs.appendingPathComponent("config.json"))
        do {
            let folder = try ClusterModelStore.cloneFolder(artifact: model.artifact, from: from, into: store)
            expect(folder == model.artifact.folderName, "cloned under its folder name")
            expect(FileManager.default.fileExists(atPath: theirs.appendingPathComponent("config.json").path), "another clone's staging is left alone")
            for (path, data) in model.files {
                expect((try? Data(contentsOf: store.appendingPathComponent(model.artifact.folderName).appendingPathComponent(path))) == data, "clone: \(path)")
            }
            expect(ClusterModelStore.holding(store: store, artifact: model.artifact) == .complete(folder: model.artifact.folderName), "the clone is held")
            // A second clone (the other process finishing later) neither fails loudly nor touches the placed folder.
            expect(try ClusterModelStore.cloneFolder(artifact: model.artifact, from: from, into: store) == nil, "a second clone finds it there")
            // A clone whose source lost a file leaves nothing behind.
            let broken = source(model)
            try FileManager.default.removeItem(at: broken.appendingPathComponent("tokenizer.json"))
            let store2 = temporary("store2")
            refuses("missing") { _ = try ClusterModelStore.cloneFolder(artifact: model.artifact, from: broken, into: store2) }
            let left = ((try? FileManager.default.contentsOfDirectory(atPath: store2.path)) ?? [])
            expect(left.isEmpty, "a failed clone leaves no folder and no staging: \(left)")
        } catch { expect(false, "clone: \(error)") }
    }

    /// The rename into place is exclusive: a folder that appeared at the destination after `begin` (even an empty one)
    /// is never replaced.
    static func commitNeverReplacesAFolder() {
        let model = fixture()
        let store = temporary("store")
        do {
            let receiver = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil)
            _ = try send(try ClusterModelSender(artifact: model.artifact, directory: source(model)), to: receiver, from: try receiver.begin().offsets)
            try FileManager.default.createDirectory(at: store.appendingPathComponent(model.artifact.folderName), withIntermediateDirectories: false)
            refuses("could not be put in place") { _ = try receiver.commit() }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: store.appendingPathComponent(model.artifact.folderName).path)) ?? ["?"]
            expect(names.isEmpty, "the folder that appeared is left as it was: \(names)")
        } catch { expect(false, "exclusive commit: \(error)") }
    }

    /// An abandoned copy of another model (the person chose something else) stays hidden in the store; when the disk
    /// is short it is reclaimed before the copy is refused, so hidden staging never starves the disk.
    static func abandonedStagingReclaimedForSpace() {
        let model = fixture(), other = fixture(modelID: "Example/Other-Model")
        let store = temporary("store")
        do {
            let first = try ClusterModelReceiver(artifact: other.artifact, store: store, folder: other.artifact.folderName, expectedAggregate: nil)
            _ = try send(try ClusterModelSender(artifact: other.artifact, directory: source(other)), to: first, from: try first.begin().offsets, stopAfterBytes: 1 << 20)
            let abandoned = store.appendingPathComponent(ClusterModelStore.stagingName(other.artifact))
            expect(FileManager.default.fileExists(atPath: abandoned.path), "fixture: an abandoned staging folder")
            // Free space counts the abandoned bytes as used: without them the copy fits, with them it does not.
            let need = model.artifact.totalBytes + ClusterModelProvisioning.reserveBytes
            let receiver = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil,
                freeBytes: { _ in FileManager.default.fileExists(atPath: abandoned.path) ? need - 1 : need })
            let state = try receiver.begin()
            expect(!state.complete, "the copy starts once the abandoned staging is reclaimed")
            expect(!FileManager.default.fileExists(atPath: abandoned.path), "the abandoned staging was reclaimed")
            // Its own staging is never reclaimed for itself (the resume is kept).
            let again = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil,
                freeBytes: { _ in 1 })
            refuses("free; the copy needs") { _ = try again.begin() }
            expect(FileManager.default.fileExists(atPath: store.appendingPathComponent(ClusterModelStore.stagingName(model.artifact)).path),
                "a copy's own staging stays for its resume")
        } catch { expect(false, "reclaim: \(error)") }
    }

    // MARK: - Finish 2026-10-13 night

    /// The fixture's manifest with `config.json` renamed (the files keep their order, so the aggregate digest, which
    /// covers the file digests only, is unchanged): what a paired peer could send under an approved digest.
    static func renamedFiles(_ model: (files: [(String, Data)], manifest: Data, artifact: ClusterCatalogArtifact))
        -> (files: [(String, Data)], manifest: Data, artifact: ClusterCatalogArtifact) {
        var object = try! JSONSerialization.jsonObject(with: model.manifest) as! [String: Any]
        var entries = object["files"] as! [[String: Any]]
        for index in entries.indices where entries[index]["path"] as? String == "config.json" { entries[index]["path"] = "config.jsom" }
        object["files"] = entries
        let manifest = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let files = model.files.map { ($0.0 == "config.json" ? "config.jsom" : $0.0, $0.1) }
        return (files, manifest, try! ClusterCatalogArtifact.parse(manifest: manifest))
    }

    /// File-name binding: a folder whose manifest renames the files is not the artifact, and a copy of the real one
    /// into that folder is refused in words instead of being taken as "already here".
    static func renamedFilesAreNotTheArtifact() {
        let model = fixture()
        let bad = renamedFiles(model)
        expect(bad.artifact.aggregateSHA256 == model.artifact.aggregateSHA256, "fixture: renamed files keep the aggregate digest")
        expect(bad.artifact.filesDigest != model.artifact.filesDigest, "the files digest binds the names")
        expect(!model.artifact.sameArtifact(bad.artifact) && model.artifact.sameArtifact(model.artifact), "sameArtifact compares names too")
        let store = temporary("store")
        do {
            // The pure receiver (no worker check) places the renamed copy under the real folder name...
            let receiver = try ClusterModelReceiver(artifact: bad.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil)
            _ = try send(try ClusterModelSender(artifact: bad.artifact, directory: source(bad)), to: receiver, from: try receiver.begin().offsets)
            _ = try receiver.commit()
            // ...but the store never lists it as holding the real artifact,
            expect(ClusterModelStore.holding(store: store, artifact: model.artifact) != .complete(folder: model.artifact.folderName),
                "a folder of renamed files is not held: \(ClusterModelStore.holding(store: store, artifact: model.artifact))")
            // and the real copy into that folder is refused in words, not answered "already here".
            refuses("with other contents") {
                let state = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil).begin()
                if state.complete { throw ClusterModelProvisioningError("already here") }
            }
        } catch { expect(false, "renamed files: \(error)") }
    }

    /// The receiving Mac's own worker check runs on the complete staged folder before the exclusive rename: a refusal
    /// discards the copy (no folder appears, no staging is kept); the real files pass and are placed.
    static func stagedCheckRefusesRenamedCopy() {
        let model = fixture()
        let bad = renamedFiles(model)
        // Stands in for `--describe-runtime`: the registered configuration and manifest bytes, read from the folder.
        final class Seen: @unchecked Sendable { var folders = [URL]() }
        let seen = Seen()
        let check: (URL) -> String? = { staged in
            seen.folders.append(staged)
            guard (try? Data(contentsOf: staged.appendingPathComponent("config.json"))) == model.files[0].1 else { return "the configuration is not a registered resident model's" }
            guard (try? Data(contentsOf: staged.appendingPathComponent("manifest.json"))) == model.manifest else { return "the manifest is not the registered one" }
            return nil
        }
        let store = temporary("store")
        do {
            let receiver = try ClusterModelReceiver(artifact: bad.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil, stagedCheck: check)
            _ = try send(try ClusterModelSender(artifact: bad.artifact, directory: source(bad)), to: receiver, from: try receiver.begin().offsets)
            refuses("cluster worker refused the copied Example/Tiny-Model 2026-10-13-r1: the configuration is not a registered resident model's; the copy was discarded") {
                _ = try receiver.commit()
            }
            expect(seen.folders.count == 1 && seen.folders[0].lastPathComponent == ClusterModelStore.stagingName(model.artifact),
                "the check ran once, on the staged folder: \(seen.folders.map(\.lastPathComponent))")
            expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent(model.artifact.folderName).path), "no folder appears for a refused copy")
            expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent(ClusterModelStore.stagingName(model.artifact)).path),
                "the refused staging is discarded (renamed bytes are never resumed into the real names)")
            let good = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil, stagedCheck: check)
            _ = try send(try ClusterModelSender(artifact: model.artifact, directory: source(model)), to: good, from: try good.begin().offsets)
            let placed = try good.commit()
            expect(placed.lastPathComponent == model.artifact.folderName && seen.folders.count == 2, "the real files pass the worker check and are placed")
            expect(ClusterModelStore.holding(store: store, artifact: model.artifact) == .complete(folder: model.artifact.folderName), "and are held")
        } catch { expect(false, "staged check: \(error)") }
    }

    /// Something else fills the disk during the copy: it stops with the reason in words, the staged bytes stay, and
    /// the next copy resumes from them.
    static func diskFilledDuringCopyStopsCleanly() {
        let model = fixture()
        let from = source(model)
        let store = temporary("store")
        final class Disk: @unchecked Sendable { let lock = NSLock(); var free: Int64 = 100_000_000_000; var reads = 0 }
        let disk = Disk()
        do {
            let receiver = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil,
                diskCheckBytes: 1 << 20, freeBytes: { _ in disk.lock.withLock { disk.reads += 1; return disk.free } })
            let state = try receiver.begin()
            let readsAtBegin = disk.lock.withLock { disk.reads }
            let sender = try ClusterModelSender(artifact: model.artifact, directory: from)
            _ = try send(sender, to: receiver, from: state.offsets, stopAfterBytes: 2 << 20)
            expect(disk.lock.withLock { disk.reads } > readsAtBegin, "free disk is read again during the copy")
            disk.lock.withLock { disk.free = 900_000_000 }   // another writer took the space
            refuses("free disk fell to 0.9 GB during the copy (something else is writing to it)") {
                _ = try send(sender, to: receiver, from: [model.artifact.files[0].sizeBytes, model.artifact.files[1].sizeBytes, 2 << 20, 0])
            }
            if case .partial(let bytes) = ClusterModelStore.holding(store: store, artifact: model.artifact) {
                expect(bytes >= 2 << 20, "the staged bytes are kept for the resume: \(bytes)")
            } else { expect(false, "a stopped copy keeps its staging: \(ClusterModelStore.holding(store: store, artifact: model.artifact))") }
            expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent(model.artifact.folderName).path), "nothing placed")
            disk.lock.withLock { disk.free = 100_000_000_000 }
            let again = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil,
                diskCheckBytes: 1 << 20, freeBytes: { _ in disk.lock.withLock { disk.free } })
            let resumed = try again.begin()
            expect(resumed.offsets[0] == model.artifact.files[0].sizeBytes && resumed.offsets[2] > 0, "the copy resumes from the staged bytes: \(resumed.offsets)")
            _ = try send(sender, to: again, from: resumed.offsets)
            let placed = try again.commit()
            for (path, data) in model.files { expect((try? Data(contentsOf: placed.appendingPathComponent(path))) == data, "resumed after the disk stop: \(path)") }
        } catch { expect(false, "disk filled during the copy: \(error)") }
    }

    /// Only a long copy is asked for: under 30 s at the rate measured on these Macs it starts with a stated line.
    static func shortCopiesAreNotAskedFor() {
        typealias P = ClusterModelProvisioning
        typealias Mac = ClusterModelProvisioningMac
        func plan(_ bytes: Int64, rate: Double?, leaderHas: Bool = true, free: Int64? = nil) -> ClusterModelProvisioningPlan {
            P.plan(totalBytes: bytes, leader: Mac(name: "A", holding: leaderHas ? .complete(folder: "m") : .missing, freeBytes: nil),
                members: [Mac(name: "B", holding: .missing, freeBytes: free)], linkBytesPerSecond: rate, catalogHasIt: true)
        }
        let nine = plan(6_100_000_000, rate: 2e9)
        expect(P.predictedCopySeconds(nine).map { abs($0 - 3.05) < 0.01 } == true && P.quickCopySeconds(nine) != nil, "6.1 GB at 2 GB/s: about 3 s, not asked")
        let big = plan(16_300_000_000, rate: 0.5e9)
        expect(P.predictedCopySeconds(big).map { $0 > 30 } == true && P.quickCopySeconds(big) == nil, "16.3 GB at 0.5 GB/s: over 30 s, asked")
        expect(P.quickCopySeconds(plan(6_100_000_000, rate: nil)) == nil, "no measured rate: the time is unknown, asked")
        expect(P.quickCopySeconds(plan(6_100_000_000, rate: 2e9, leaderHas: false)) == nil, "no Mac has it (the leader downloads first): asked")
        expect(P.quickCopySeconds(plan(6_100_000_000, rate: 2e9, free: 1_000_000_000)) == nil, "a copy that cannot start is not started")
        let fromMember = P.plan(totalBytes: 6_100_000_000, leader: Mac(name: "A", holding: .missing, freeBytes: nil),
            members: [Mac(name: "B", holding: .complete(folder: "m"), freeBytes: nil)], linkBytesPerSecond: 2e9, catalogHasIt: false)
        expect(P.quickCopySeconds(fromMember) != nil, "a member sending to the leader is a copy too: predicted, not asked")
    }

    // MARK: - Finish review 2026-10-13 night

    /// The staging folder is named by the aggregate digest, which a renamed manifest keeps: a paired peer that sends an
    /// approved model under other names and stops before the commit leaves those names (and a folder where a real file
    /// belongs) in the staging the real copy then resumes into. The real copy must neither be wedged by them nor carry
    /// them into the placed folder (placement reads every `*.safetensors` of a folder); files that appear in the staging
    /// during a copy refuse the commit.
    static func stagingHoldsOnlyTheManifestFiles() {
        let model = fixture()
        // Same digests in the same path order (same aggregate): config.json becomes a folder, tokenizer.json an extra shard.
        var object = try! JSONSerialization.jsonObject(with: model.manifest) as! [String: Any]
        var entries = object["files"] as! [[String: Any]]
        let renames = ["config.json": "config.json/x", "tokenizer.json": "zz-extra.safetensors"]
        for index in entries.indices { if let to = renames[entries[index]["path"] as! String] { entries[index]["path"] = to } }
        object["files"] = entries
        let badManifest = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let bad = (files: model.files.map { (renames[$0.0] ?? $0.0, $0.1) }, manifest: badManifest, artifact: try! ClusterCatalogArtifact.parse(manifest: badManifest))
        expect(bad.artifact.aggregateSHA256 == model.artifact.aggregateSHA256, "fixture: the renamed manifest keeps the aggregate digest")
        let check: (URL) -> String? = { staged in
            (try? Data(contentsOf: staged.appendingPathComponent("manifest.json"))) == model.manifest ? nil : "the manifest is not the registered one"
        }
        let store = temporary("store")
        let staging = store.appendingPathComponent(ClusterModelStore.stagingName(model.artifact))
        do {
            // The peer sends every renamed file, then stops before the commit.
            let attacker = try ClusterModelReceiver(artifact: bad.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil, stagedCheck: check)
            _ = try send(try ClusterModelSender(artifact: bad.artifact, directory: source(bad)), to: attacker, from: try attacker.begin().offsets)
            try Data("left by something else".utf8).write(to: staging.appendingPathComponent("leftover.bin"))
            // The real copy resumes into that staging: not wedged, and only the manifest's files are placed.
            let good = try ClusterModelReceiver(artifact: model.artifact, store: store, folder: model.artifact.folderName, expectedAggregate: nil, stagedCheck: check)
            let state = try good.begin()
            expect(state.offsets[2] == model.artifact.files[2].sizeBytes, "real files under their real names are kept for the resume: \(state.offsets)")
            _ = try send(try ClusterModelSender(artifact: model.artifact, directory: source(model)), to: good, from: state.offsets)
            let placed = try good.commit()
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: placed.path)) ?? [])
            expect(names == Set(model.files.map(\.0) + ["manifest.json"]), "the placed folder holds exactly the manifest's files: \(names.sorted())")
            for (path, data) in model.files { expect((try? Data(contentsOf: placed.appendingPathComponent(path))) == data, "placed \(path) byte for byte") }
        } catch { expect(false, "staging left by a renamed copy: \(error)") }
        // A manifest with files in a subfolder (as MiMo's audio_tokenizer/) commits: the folders on the way are its own.
        let store3 = temporary("store3")
        do {
            let nested = try ClusterModelReceiver(artifact: bad.artifact, store: store3, folder: "nested", expectedAggregate: nil)
            _ = try send(try ClusterModelSender(artifact: bad.artifact, directory: source(bad)), to: nested, from: try nested.begin().offsets)
            let placed = try nested.commit()
            expect((try? Data(contentsOf: placed.appendingPathComponent("config.json/x"))) == model.files[0].1, "a file in a subfolder is placed")
        } catch { expect(false, "subfolder manifest: \(error)") }
        // A file that appears in the staging during the copy refuses the commit; nothing is placed.
        let store2 = temporary("store2")
        do {
            let receiver = try ClusterModelReceiver(artifact: model.artifact, store: store2, folder: model.artifact.folderName, expectedAggregate: nil, stagedCheck: check)
            _ = try send(try ClusterModelSender(artifact: model.artifact, directory: source(model)), to: receiver, from: try receiver.begin().offsets)
            try Data("x".utf8).write(to: store2.appendingPathComponent(ClusterModelStore.stagingName(model.artifact)).appendingPathComponent("extra.safetensors"))
            refuses("besides its manifest's files (extra.safetensors); the copy was discarded") { _ = try receiver.commit() }
            expect(!FileManager.default.fileExists(atPath: store2.appendingPathComponent(model.artifact.folderName).path), "nothing placed with an extra file")
        } catch { expect(false, "extra file during the copy: \(error)") }
    }

    static func wireRoundTrip() {
        let payload = Data((0..<1000).map { UInt8($0 & 0xFF) })
        let frame = ClusterModelTransferWire.chunk(index: 3, offset: 5_000_000_123, payload)
        let parsed = ClusterModelTransferWire.parseChunk(frame)
        expect(parsed?.index == 3 && parsed?.offset == 5_000_000_123 && parsed?.bytes == payload, "chunk frame round trip")
        expect(ClusterModelTransferWire.parseChunk(Data([1, 2, 3])) == nil, "a short frame is refused")
    }
}

extension Double { var int: Int64 { Int64(self) } }
