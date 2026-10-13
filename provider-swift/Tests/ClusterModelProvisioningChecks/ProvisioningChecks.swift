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
        print("provisioning checks: \(passed) passed, \(failures.count) failed")
        for failure in failures { print("FAIL " + failure) }
        exit(failures.isEmpty ? 0 : 1)
    }

    // MARK: - Fixtures

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A small model: a config, a tokenizer and two weight shards (one larger than a chunk), with its manifest.
    static func fixture(modelID: String = "Example/Tiny-Model", version: String = "2026-10-13-r1")
        -> (files: [(String, Data)], manifest: Data, artifact: ClusterModelArtifact) {
        var generator = SystemRandomNumberGenerator()
        func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }) }
        let files: [(String, Data)] = [("config.json", Data("{\"num_hidden_layers\":2}".utf8)), ("tokenizer.json", random(3000)),
                                       ("model-00001-of-00002.safetensors", random(3 << 20)), ("model-00002-of-00002.safetensors", random(70_000))]
        let entries = files.map { ["path": $0.0, "size_bytes": $0.1.count, "sha256": sha($0.1), "role": "weight"] as [String: Any] }
        let artifactFiles = files.map { ClusterModelArtifact.File(path: $0.0, sizeBytes: Int64($0.1.count), sha256: sha($0.1)) }
        let object: [String: Any] = ["schema_version": 1, "model_id": modelID, "version": version, "r2_prefix": "v2/x/\(version)",
            "aggregate_sha256": ClusterModelArtifact.aggregateDigest(artifactFiles), "total_size_bytes": files.reduce(0) { $0 + $1.1.count },
            "file_count": files.count, "files": entries, "created_at": "2026-10-13T00:00:00Z"]
        let manifest = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return (files, manifest, try! ClusterModelArtifact.parse(manifest: manifest))
    }

    static func temporary(_ name: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("prov-\(name)-\(UUID().uuidString.prefix(8))")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func source(_ fixture: (files: [(String, Data)], manifest: Data, artifact: ClusterModelArtifact)) -> URL {
        let directory = temporary("source").appendingPathComponent(fixture.artifact.folderName)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, data) in fixture.files { try! data.write(to: directory.appendingPathComponent(path)) }
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
        func mutated(_ change: (inout [String: Any]) -> Void) -> Data {
            var object = try! JSONSerialization.jsonObject(with: model.manifest) as! [String: Any]
            change(&object)
            return try! JSONSerialization.data(withJSONObject: object)
        }
        refuses("aggregate") { _ = try ClusterModelArtifact.parse(manifest: mutated { $0["aggregate_sha256"] = String(repeating: "a", count: 64) }) }
        refuses("aggregate") { _ = try ClusterModelArtifact.parse(manifest: mutated {
            var files = $0["files"] as! [[String: Any]]; files[1]["sha256"] = String(repeating: "b", count: 64); $0["files"] = files }) }
        refuses("unsafe") { _ = try ClusterModelArtifact.parse(manifest: mutated {
            var files = $0["files"] as! [[String: Any]]; files[0]["path"] = "../../etc/passwd"; $0["files"] = files }) }
        refuses("unsafe") { _ = try ClusterModelArtifact.parse(manifest: mutated {
            var files = $0["files"] as! [[String: Any]]; files[0]["path"] = ".darkbloom-manifest.json"; $0["files"] = files }) }
        refuses("unsafe") { _ = try ClusterModelArtifact.parse(manifest: mutated {
            var files = $0["files"] as! [[String: Any]]; files[0]["path"] = "/abs/config.json"; $0["files"] = files }) }
        refuses("unsafe, duplicate") { _ = try ClusterModelArtifact.parse(manifest: mutated {
            var files = $0["files"] as! [[String: Any]]; files[1]["path"] = "CONFIG.JSON"; $0["files"] = files }) }
        refuses("total") { _ = try ClusterModelArtifact.parse(manifest: mutated { $0["total_size_bytes"] = 1 }) }
        refuses("file count") { _ = try ClusterModelArtifact.parse(manifest: mutated { $0["file_count"] = 9 }) }
        refuses("identity") { _ = try ClusterModelArtifact.parse(manifest: mutated { $0["model_id"] = nil }) }
        refuses("cannot be read") { _ = try ClusterModelArtifact.parse(manifest: Data("not json".utf8)) }
        expect(ClusterModelArtifact.safeFolder("Qwen3.5-9B-2026-09-03-r1") != nil, "a catalog folder name is safe")
        expect(ClusterModelArtifact.safeFolder("a/b") == nil && ClusterModelArtifact.safeFolder(".hidden") == nil
            && ClusterModelArtifact.safeFolder("..") == nil, "nested, hidden and parent names are not")
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

    static func wireRoundTrip() {
        let payload = Data((0..<1000).map { UInt8($0 & 0xFF) })
        let frame = ClusterModelTransferWire.chunk(index: 3, offset: 5_000_000_123, payload)
        let parsed = ClusterModelTransferWire.parseChunk(frame)
        expect(parsed?.index == 3 && parsed?.offset == 5_000_000_123 && parsed?.bytes == payload, "chunk frame round trip")
        expect(ClusterModelTransferWire.parseChunk(Data([1, 2, 3])) == nil, "a short frame is refused")
    }
}

extension Double { var int: Int64 { Int64(self) } }
