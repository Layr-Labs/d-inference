import Foundation
import Darwin
import CryptoKit

// Model provisioning for `darkbloom cluster` (owner feature 2026-10-13: no manual model downloads for clustering).
//
// The leader lists the models it has (the cluster's model store and the product's single-Mac store) and the catalog
// models it could fetch. Each member compares what it holds for the chosen model with the leader BY THE CATALOG
// MANIFEST'S DIGESTS (the aggregate SHA-256 and every file's SHA-256), never by names. A member that lacks it gets it
// copied from a Mac that has it over the paired, authenticated, encrypted link control channel (the pairing's keys;
// never plain TCP, never SSH); when no Mac has it, the leader downloads it from the catalog exactly as single-Mac
// Darkbloom does and then copies it. Every byte is verified against the manifest before the folder appears.
//
// This file is pure (Foundation, Darwin, CryptoKit): the manifest checks, the decision between copy and download,
// the receiver (staging, uncached writes, resume, verification, single-link files, free-disk check, atomic rename)
// and the sender's uncached reads, so a check drives all of it with plain swiftc and temporary folders.

/// One model artifact as its catalog manifest describes it: identity, files and their SHA-256 digests.
public struct ClusterCatalogArtifact: Sendable, Equatable {
    public struct File: Sendable, Equatable, Codable {
        public var path: String
        public var sizeBytes: Int64
        public var sha256: String
        public init(path: String, sizeBytes: Int64, sha256: String) { self.path = path; self.sizeBytes = sizeBytes; self.sha256 = sha256 }
    }

    public static let maximumManifestBytes = 1 << 20
    public static let maximumFiles = 4096

    public var modelID: String
    public var version: String
    /// The catalog identity: SHA-256 over the files' raw digests in path order (as `darkbloom-publish hash` writes it).
    public var aggregateSHA256: String
    public var totalBytes: Int64
    public var files: [File]
    /// The manifest's exact bytes, written beside the files as `manifest.json`.
    public var manifest: Data
    /// Where the catalog publishes the files (`r2_prefix`), when the manifest names it.
    public var r2Prefix: String?

    /// The same catalog entry: model ID, version and aggregate digest. The digest alone is not an entry's identity: two
    /// entries can share every file (the catalog's gemma-4-26b and gemma-4-26b-8bit do), and the runtime tells them
    /// apart by the manifest.
    public func sameEntry(modelID: String, version: String, aggregate: String) -> Bool {
        aggregate == aggregateSHA256 && modelID == self.modelID && version == self.version
    }

    /// The folder name the cluster's model store uses: the model ID's last part and the catalog version.
    public var folderName: String {
        let base = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return ClusterCatalogArtifact.safeFolder(base + "-" + version) ?? "model-" + String(aggregateSHA256.prefix(16))
    }

    /// Parses and checks a catalog manifest. Refuses unsafe paths, duplicates, bad digests, a total that does not add
    /// up, and an aggregate digest that does not match the files' digests (so every file digest is bound to the
    /// catalog identity a member checks).
    public static func parse(manifest data: Data) throws -> ClusterCatalogArtifact {
        guard data.count <= maximumManifestBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClusterModelProvisioningError("the model's manifest cannot be read")
        }
        guard let modelID = object["model_id"] as? String, !modelID.isEmpty, modelID.utf8.count <= 256,
              let version = object["version"] as? String, !version.isEmpty, version.utf8.count <= 64,
              let aggregate = object["aggregate_sha256"] as? String, digest(aggregate),
              let total = (object["total_size_bytes"] as? NSNumber)?.int64Value,
              let entries = object["files"] as? [[String: Any]], !entries.isEmpty, entries.count <= maximumFiles else {
            throw ClusterModelProvisioningError("the model's manifest lacks its identity or files")
        }
        if let count = (object["file_count"] as? NSNumber)?.intValue, count != entries.count {
            throw ClusterModelProvisioningError("the model's manifest file count does not match its files")
        }
        var files = [File](), seen = Set<String>(), sum: Int64 = 0
        for entry in entries {
            guard let path = entry["path"] as? String, safePath(path),
                  let size = (entry["size_bytes"] as? NSNumber)?.int64Value, size >= 0,
                  let sha = entry["sha256"] as? String, digest(sha),
                  seen.insert(path.lowercased()).inserted, path.lowercased() != "manifest.json" else {
                throw ClusterModelProvisioningError("the model's manifest names an unsafe, duplicate or malformed file")
            }
            let (next, overflow) = sum.addingReportingOverflow(size)
            guard !overflow else { throw ClusterModelProvisioningError("the model's manifest sizes overflow") }
            sum = next
            files.append(.init(path: path, sizeBytes: size, sha256: sha))
        }
        guard sum == total else { throw ClusterModelProvisioningError("the model's manifest total does not match its files") }
        guard aggregateDigest(files) == aggregate else {
            throw ClusterModelProvisioningError("the model's manifest digests do not match its aggregate digest")
        }
        let prefix = (object["r2_prefix"] as? String).flatMap { safePath($0) ? $0 : nil }
        return .init(modelID: modelID, version: version, aggregateSHA256: aggregate, totalBytes: total, files: files, manifest: data, r2Prefix: prefix)
    }

    /// SHA-256 over every file's path, size and digest in path order. The aggregate digest covers the file digests
    /// only, so a manifest that renames files (keeping their order) keeps it; this digest binds the NAMES too, and two
    /// manifests of one entry compare equal only when they place the same bytes under the same names.
    public var filesDigest: String { Self.filesDigest(files) }

    public static func filesDigest(_ files: [File]) -> String {
        var hasher = SHA256()
        // Paths hold no control character (`safePath`), so NUL and newline separate the fields unambiguously.
        for file in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data((file.path + "\u{0}" + String(file.sizeBytes) + "\u{0}" + file.sha256 + "\n").utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The same entry with the same files under the same names (`sameEntry` plus `filesDigest`).
    /// The same files (path, size, digest) in any order. The CDN's manifest lists them in another order than the
    /// product store's receipt and the coordinator's re-encoding: compared in order, the CDN's exact bytes were refused
    /// and the coordinator's re-encoded manifest was written instead, which the worker's manifest pin then refused
    /// (Qwen 3.5 9B and Qwen 3.8 27B on the 2x Mac pair, 2026-10-15).
    public static func sameFiles(_ a: [File], _ b: [File]) -> Bool {
        a.count == b.count && a.sorted(by: { $0.path < $1.path }) == b.sorted(by: { $0.path < $1.path })
    }

    public func sameArtifact(_ other: ClusterCatalogArtifact) -> Bool {
        sameEntry(modelID: other.modelID, version: other.version, aggregate: other.aggregateSHA256) && filesDigest == other.filesDigest
    }

    /// SHA-256 over the raw per-file digests in path order.
    public static func aggregateDigest(_ files: [File]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) { hasher.update(data: hexBytes(file.sha256)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func hexBytes(_ hex: String) -> Data {
        var data = Data(capacity: hex.utf8.count / 2)
        var high: UInt8?
        for byte in hex.utf8 {
            let value: UInt8 = byte <= 57 ? byte - 48 : byte - 87
            if let h = high { data.append(h << 4 | value); high = nil } else { high = value }
        }
        return data
    }

    /// A relative path of plain components: no leading slash, no backslash, no empty, `.` or `..` component, no
    /// hidden component (the product store's own files are hidden), no control character.
    static func safePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    /// A single safe folder name, or nil.
    public static func safeFolder(_ name: String) -> String? {
        guard safePath(name), !name.contains("/"), name.utf8.count <= 128 else { return nil }
        return name
    }
}

public struct ClusterModelProvisioningError: Error, Sendable, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ text: String) { description = text }
}

// MARK: - What a Mac holds

/// What one Mac holds of one artifact, by digest.
public enum ClusterModelHolding: Sendable, Equatable, Codable {
    /// A folder of the store whose manifest has the artifact's aggregate digest.
    case complete(folder: String)
    /// An interrupted copy: this many bytes already verified or staged (resumable).
    case partial(bytes: Int64)
    case missing

    public var complete: Bool { if case .complete = self { return true }; return false }
}

public enum ClusterModelStore {
    /// Staging folders are hidden from every listing: a folder appears only after its last byte is verified.
    public static func stagingName(_ artifact: ClusterCatalogArtifact) -> String { ".darkbloom-incoming-" + String(artifact.aggregateSHA256.prefix(32)) }

    /// The folders of `store` whose manifest names this catalog entry (model ID, version, aggregate digest) with the
    /// same files under the same names (the aggregate digest does not cover names: a folder whose manifest renames the
    /// files is not this artifact). Manifests only: the worker verifies the weights before anything is served, and a
    /// copy verifies every byte as it arrives.
    public static func holding(store: URL, artifact: ClusterCatalogArtifact) -> ClusterModelHolding {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []).sorted()
        for name in names where !name.hasPrefix(".") {
            guard let data = readSmall(store.appendingPathComponent(name).appendingPathComponent("manifest.json")),
                  let held = try? ClusterCatalogArtifact.parse(manifest: data), artifact.sameArtifact(held) else { continue }
            return .complete(folder: name)
        }
        let staging = store.appendingPathComponent(stagingName(artifact))
        var bytes: Int64 = 0
        for file in artifact.files {
            for suffix in ["", ".part"] {
                var info = stat()
                if lstat(staging.appendingPathComponent(file.path + suffix).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
                    bytes += min(Int64(info.st_size), file.sizeBytes)
                }
            }
        }
        return bytes > 0 ? .partial(bytes: bytes) : .missing
    }

    /// Drops the pages macOS keeps in its file cache for every regular file directly in `folder` (a model's weights),
    /// as a shared mapping invalidated with `msync(MS_INVALIDATE)`: no privileges, the files are untouched. A load
    /// gate counts only the file cache the kernel can take before applications' memory; right after a download the
    /// model's own pages sat in the active cache on a 36 GB M4 Max (23 GB file-backed, 0.09 GB counted) and its share
    /// of the next start was refused (2026-10-16). Returns the bytes asked to drop; best effort.
    @discardableResult
    public static func dropCachedPages(folder: URL) -> Int64 {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var dropped: Int64 = 0
        for name in names where !name.hasPrefix(".") {
            let path = folder.appendingPathComponent(name).path
            // Non-blocking (a FIFO swapped in must not hang the caller), then judged by what was opened.
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var information = stat()
            guard fstat(fd, &information) == 0, information.st_mode & S_IFMT == S_IFREG, information.st_size > 0 else { continue }
            let length = Int(information.st_size)
            guard let mapping = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0), mapping != MAP_FAILED else { continue }
            if msync(mapping, length, MS_INVALIDATE) == 0 { dropped += Int64(length) }
            munmap(mapping, length)
        }
        return dropped
    }

    /// A small regular file (no symbolic link) of at most 1 MiB.
    static func readSmall(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 1 << 20 else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        return count == Int(info.st_size) ? data : nil
    }

    /// Free bytes on the volume that holds `url` (or its nearest existing parent), as macOS offers them to an app.
    public static func freeBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        if let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        var info = statfs()
        guard statfs(probe.path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }
}

// MARK: - Copy or download: the decision

/// Where a Mac gets the chosen model from.
public enum ClusterModelSource: Sendable, Equatable {
    /// It has it already (same aggregate digest).
    case present
    /// Copied from the named Mac over the Thunderbolt cable.
    case copy(from: String)
    /// Downloaded from the catalog source, as single-Mac Darkbloom does.
    case download
}

public struct ClusterModelProvisioningPlan: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        public var mac: String
        public var source: ClusterModelSource
        /// Bytes still to move (a resumed copy counts only what is left).
        public var bytes: Int64
        public var seconds: Double?
        /// Why it cannot start (not enough free disk), nil when it can.
        public var blocker: String?
    }
    public var steps: [Step]
    /// Nothing to move: every Mac has it.
    public var ready: Bool { steps.allSatisfy { $0.source == .present } }
    public var blocker: String? { steps.compactMap(\.blocker).first }
}

/// One Mac as the decision sees it.
public struct ClusterModelProvisioningMac: Sendable, Equatable {
    public var name: String
    public var holding: ClusterModelHolding
    public var freeBytes: Int64?
    public init(name: String, holding: ClusterModelHolding, freeBytes: Int64?) { self.name = name; self.holding = holding; self.freeBytes = freeBytes }
}

public enum ClusterModelProvisioning {
    /// Room kept free beyond the model itself, so a copy never fills a disk.
    public static let reserveBytes: Int64 = 2 << 30

    /// The plan for one model: every Mac that lacks it copies it from a Mac that has it (the leader first), over the
    /// cable; when no Mac has it, the leader downloads it from the catalog and the others copy it from the leader.
    /// `preferDownload` is the person's choice of the catalog over the cable for the members. Universal: any number
    /// of members, any model; the link speed is measured on these Macs (nil: no estimate shown).
    public static func plan(totalBytes: Int64, leader: ClusterModelProvisioningMac, members: [ClusterModelProvisioningMac],
                            linkBytesPerSecond: Double?, downloadBytesPerSecond: Double? = nil,
                            catalogHasIt: Bool, preferDownload: Bool = false) -> ClusterModelProvisioningPlan {
        func remaining(_ holding: ClusterModelHolding) -> Int64 {
            switch holding {
            case .complete: return 0
            case .partial(let bytes): return max(0, totalBytes - bytes)
            case .missing: return totalBytes
            }
        }
        func step(_ mac: ClusterModelProvisioningMac, _ source: ClusterModelSource, rate: Double?) -> ClusterModelProvisioningPlan.Step {
            let bytes = source == .present ? 0 : remaining(mac.holding)
            var blocker: String?
            if source != .present, let free = mac.freeBytes, free < bytes + reserveBytes {
                blocker = "\(mac.name) has \(gigabytes(free)) free; the model needs \(gigabytes(bytes)) and \(gigabytes(reserveBytes)) to spare"
            }
            if source == .download, !catalogHasIt { blocker = blocker ?? "no Mac has it and the catalog does not offer it" }
            let seconds = rate.flatMap { $0 > 0 && bytes > 0 ? Double(bytes) / $0 : nil }
            return .init(mac: mac.name, source: source, bytes: bytes, seconds: seconds, blocker: blocker)
        }
        let leaderHas = leader.holding.complete
        let holder = leaderHas ? leader.name : members.first(where: { $0.holding.complete })?.name
        var steps = [ClusterModelProvisioningPlan.Step]()
        // The leader plans from the model's own files, so it holds it first: copied from a member that has it, else downloaded.
        if leaderHas { steps.append(step(leader, .present, rate: nil)) }
        else if let holder { steps.append(step(leader, .copy(from: holder), rate: linkBytesPerSecond)) }
        else { steps.append(step(leader, .download, rate: downloadBytesPerSecond)) }
        let source = holder ?? leader.name
        for member in members {
            if member.holding.complete { steps.append(step(member, .present, rate: nil)); continue }
            if preferDownload && catalogHasIt { steps.append(step(member, .download, rate: downloadBytesPerSecond)); continue }
            steps.append(step(member, .copy(from: source), rate: linkBytesPerSecond))
        }
        return .init(steps: steps)
    }

    public static func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    /// "about 4 s", "about 3 min".
    public static func duration(_ seconds: Double) -> String {
        if seconds < 90 { return "about \(max(1, Int(seconds.rounded()))) s" }
        if seconds < 5400 { return "about \(Int((seconds / 60).rounded())) min" }
        return String(format: "about %.1f h", seconds / 3600)
    }

    /// The plan in words, one line per Mac that has something to do, then the total when more than one step moves
    /// bytes (a download and a copy are asked for once, with both in one prompt).
    public static func lines(_ plan: ClusterModelProvisioningPlan) -> [String] {
        stepLines(plan) + (totalLine(plan).map { [$0] } ?? [])
    }

    /// "In all: 32.6 GB, about 3 min" for a plan with more than one moving step; nil otherwise. The time is given
    /// only when every step's rate is known (measured on these Macs).
    public static func totalLine(_ plan: ClusterModelProvisioningPlan) -> String? {
        let moving = plan.steps.filter { $0.source != .present }
        guard moving.count > 1 else { return nil }
        let bytes = moving.reduce(Int64(0)) { $0 + $1.bytes }
        let seconds = moving.allSatisfy { $0.seconds != nil } ? moving.compactMap(\.seconds).reduce(0, +) : nil
        return "In all: \(gigabytes(bytes))" + (seconds.map { ", " + duration($0) } ?? "")
    }

    static func stepLines(_ plan: ClusterModelProvisioningPlan) -> [String] {
        plan.steps.compactMap { step in
            let eta = step.seconds.map { ", " + duration($0) } ?? ""
            let line: String
            switch step.source {
            case .present: return nil
            case .copy(let from): line = "\(step.mac): copy from \(from) over the Thunderbolt cable (\(gigabytes(step.bytes))\(eta))"
            case .download: line = "\(step.mac): download from Darkbloom's catalog (\(gigabytes(step.bytes))\(eta))"
            }
            return step.blocker.map { line + " — cannot start: " + $0 } ?? line
        }
    }

    /// A copy predicted to take less than this starts with a stated line (n still stops it); a longer one, or one
    /// whose time cannot be predicted, is asked for first.
    public static let confirmationSeconds: Double = 30

    /// The predicted time of a plan that only copies over the cable, from the copy rate measured on these Macs and the
    /// bytes left; nil when it downloads anything, cannot start, or no rate was measured yet (then it is asked for).
    public static func predictedCopySeconds(_ plan: ClusterModelProvisioningPlan) -> Double? {
        let moving = plan.steps.filter { $0.source != .present }
        guard !moving.isEmpty, plan.blocker == nil else { return nil }
        var total = 0.0
        for step in moving {
            guard case .copy = step.source, let seconds = step.seconds else { return nil }
            total += seconds
        }
        return total
    }

    /// The predicted time when the copy is short enough to start without asking (under `confirmationSeconds`), else nil.
    public static func quickCopySeconds(_ plan: ClusterModelProvisioningPlan) -> Double? {
        predictedCopySeconds(plan).flatMap { $0 < confirmationSeconds ? $0 : nil }
    }
}

// MARK: - The receiving Mac

/// What a receiving Mac reports before the bytes flow: what it holds already, what it lacks, and its free disk.
public struct ClusterModelReceiveState: Codable, Sendable, Equatable {
    /// The folder already holds this artifact: nothing to send.
    public var complete: Bool
    /// Per manifest file (manifest order): bytes already staged and verified so far (resume from here).
    public var offsets: [Int64]
    public var freeBytes: Int64?
    public var refusal: String?
}

/// Receives one artifact into a model store: staged in a hidden folder, written with the file cache off (F_NOCACHE,
/// like tools/copy-uncached.sh, so a copy does not take memory from a model load), each file hashed as it arrives and
/// checked against its manifest digest, single-linked, then the folder renamed into place in one step. An interrupted
/// copy resumes from the bytes already staged (re-read uncached and hashed once).
public final class ClusterModelReceiver: @unchecked Sendable {
    public let artifact: ClusterCatalogArtifact
    public let store: URL
    public let folder: String
    let staging: URL
    let freeBytes: @Sendable (URL) -> Int64?
    let stagedCheck: ((URL) -> String?)?
    private var current: (index: Int, fd: Int32, hasher: SHA256, written: Int64)?
    private var verified = Set<Int>()
    /// Bytes still to write (set by `begin`), and bytes written since free disk was last read.
    private var remaining: Int64 = 0
    private var sinceDiskCheck: Int64 = 0

    /// Free disk is read again after every this many bytes written (256 MiB by default): a disk something else fills
    /// during the copy stops it cleanly, with its staged bytes kept for the resume, before the disk is full.
    let diskCheckBytes: Int64

    /// Checks the artifact's identity against what the receiving Mac trusts (`expectedAggregate`: the catalog's
    /// digest for this model), the folder name, and that the destination is not something else. `stagedCheck` runs
    /// on the complete staged folder (files and manifest) right before it is put in place, and its refusal (nil:
    /// accepted) discards the copy: the cluster service runs this Mac's own installed worker's runtime description
    /// there, so file names and configuration are checked against what the worker loads, not only the digests.
    public init(artifact: ClusterCatalogArtifact, store: URL, folder: String, expectedAggregate: String?,
                trust: ((ClusterCatalogArtifact) -> String?)? = nil,
                stagedCheck: ((URL) -> String?)? = nil, diskCheckBytes: Int64 = 256 << 20,
                freeBytes: @escaping @Sendable (URL) -> Int64? = { ClusterModelStore.freeBytes(at: $0) }) throws {
        guard let safe = ClusterCatalogArtifact.safeFolder(folder) else { throw ClusterModelProvisioningError("the model folder name is not safe") }
        if let expectedAggregate, expectedAggregate != artifact.aggregateSHA256 {
            throw ClusterModelProvisioningError("the model offered is not the catalog's \(artifact.modelID) \(artifact.version) (its digest differs)")
        }
        if let refusal = trust?(artifact) { throw ClusterModelProvisioningError(refusal) }
        self.artifact = artifact; self.store = store; self.folder = safe; self.freeBytes = freeBytes; self.stagedCheck = stagedCheck
        self.diskCheckBytes = max(1, diskCheckBytes)
        staging = store.appendingPathComponent(ClusterModelStore.stagingName(artifact))
    }

    deinit { if let current { close(current.fd) } }

    var destination: URL { store.appendingPathComponent(folder) }

    /// Prepares staging and says what is there already. Refuses when the disk lacks room for what is left plus the reserve.
    public func begin() throws -> ClusterModelReceiveState {
        try makeDirectory(store)
        if case .complete(let existing) = ClusterModelStore.holding(store: store, artifact: artifact), existing == folder {
            return .init(complete: true, offsets: artifact.files.map(\.sizeBytes), freeBytes: freeBytes(store), refusal: nil)
        }
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            throw ClusterModelProvisioningError("\(folder) exists in this Mac's model store with other contents; it was left as it is")
        }
        try makeDirectory(staging)
        // The staging is named by the aggregate digest, which a manifest that renames the files keeps: whatever a copy
        // under other names left here (extra files, a folder where a file of this manifest belongs) goes, so it neither
        // wedges this copy nor rides into the placed folder.
        for unexpected in unexpectedStagingEntries(partsAllowed: true) {
            try? FileManager.default.removeItem(at: staging.appendingPathComponent(unexpected))
        }
        var offsets = [Int64]()
        for (index, file) in artifact.files.enumerated() {
            let final = staging.appendingPathComponent(file.path)
            if try fileVerified(final, file) { verified.insert(index); offsets.append(file.sizeBytes); continue }
            let part = URL(fileURLWithPath: final.path + ".part")
            var partInfo = stat()
            if lstat(part.path, &partInfo) == 0 {
                guard partInfo.st_mode & S_IFMT == S_IFREG, partInfo.st_nlink == 1, partInfo.st_uid == geteuid() else {
                    throw ClusterModelProvisioningError("a staged file of \(file.path) is not a single-linked regular file")
                }
                offsets.append(min(Int64(partInfo.st_size), file.sizeBytes))
            } else { offsets.append(0) }
        }
        let left = zip(artifact.files, offsets).reduce(Int64(0)) { $0 + $1.0.sizeBytes - $1.1 }
        var free = freeBytes(store)
        if let short = free, short < left + ClusterModelProvisioning.reserveBytes, reclaimAbandonedStaging() {
            free = freeBytes(store)
        }
        if let free, free < left + ClusterModelProvisioning.reserveBytes {
            throw ClusterModelProvisioningError("this Mac has \(ClusterModelProvisioning.gigabytes(free)) free; the copy needs \(ClusterModelProvisioning.gigabytes(left)) and \(ClusterModelProvisioning.gigabytes(ClusterModelProvisioning.reserveBytes)) to spare")
        }
        remaining = left; sinceDiskCheck = 0
        return .init(complete: false, offsets: offsets, freeBytes: free, refusal: nil)
    }

    /// Bytes of file `index` at `offset`. Files arrive in order, each from its resume offset to its end.
    public func write(index: Int, offset: Int64, _ bytes: Data) throws {
        guard artifact.files.indices.contains(index), !verified.contains(index) else {
            throw ClusterModelProvisioningError("bytes for a file that is not expected")
        }
        let file = artifact.files[index]
        if current?.index != index {
            if let current { close(current.fd); self.current = nil }
            current = try openPart(index: index, at: offset)
        }
        guard var open = current, open.written == offset, offset + Int64(bytes.count) <= file.sizeBytes else {
            throw ClusterModelProvisioningError("bytes out of order for \(file.path)")
        }
        sinceDiskCheck += Int64(bytes.count)
        if sinceDiskCheck >= diskCheckBytes {
            sinceDiskCheck = 0
            try checkFreeDisk()
        }
        try bytes.withUnsafeBytes { buffer in
            var done = 0
            while done < buffer.count {
                let count = Darwin.write(open.fd, buffer.baseAddress! + done, buffer.count - done)
                if count < 0 { if errno == EINTR { continue }; throw ClusterModelProvisioningError("writing \(file.path) failed (errno \(errno))") }
                done += count
            }
        }
        open.hasher.update(data: bytes)
        open.written += Int64(bytes.count)
        remaining = max(0, remaining - Int64(bytes.count))
        current = open
    }

    /// Something else filled the disk during the copy: stop before it is full (half the reserve is kept for macOS),
    /// with what is staged kept for the resume and the reason in words.
    private func checkFreeDisk() throws {
        guard let free = freeBytes(store) else { return }
        let keep = ClusterModelProvisioning.reserveBytes / 2
        guard free < remaining + keep else { return }
        if let open = current { _ = fsync(open.fd); close(open.fd); current = nil }
        let staged = max(0, artifact.totalBytes - remaining)
        throw ClusterModelProvisioningError("this Mac's free disk fell to \(ClusterModelProvisioning.gigabytes(free)) during the copy (something else is writing to it); the copy needs \(ClusterModelProvisioning.gigabytes(remaining)) more and \(ClusterModelProvisioning.gigabytes(keep)) to spare, so it stopped with \(ClusterModelProvisioning.gigabytes(staged)) staged and kept for the resume. Free some space and run `darkbloom cluster` again")
    }

    /// The last byte of file `index` arrived: verify its size and digest, then move it to its name.
    public func finish(index: Int) throws {
        guard artifact.files.indices.contains(index) else { throw ClusterModelProvisioningError("no such file") }
        if verified.contains(index) { return }
        let file = artifact.files[index]
        if current?.index != index { current = try openPart(index: index, at: file.sizeBytes) }
        guard let open = current, open.written == file.sizeBytes else {
            throw ClusterModelProvisioningError("\(file.path) ended early")
        }
        current = nil
        let digest = open.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        _ = fsync(open.fd)
        close(open.fd)
        let final = staging.appendingPathComponent(file.path)
        let part = URL(fileURLWithPath: final.path + ".part")
        guard digest == file.sha256 else {
            unlink(part.path)
            throw ClusterModelProvisioningError("\(file.path) does not match its manifest digest; the copy of it was discarded")
        }
        guard rename(part.path, final.path) == 0 else { throw ClusterModelProvisioningError("\(file.path) could not be put in place (errno \(errno))") }
        verified.insert(index)
    }

    /// Every file verified: writes the manifest and renames the staging folder into the store in one step.
    public func commit() throws -> URL {
        guard verified.count == artifact.files.count else {
            throw ClusterModelProvisioningError("\(artifact.files.count - verified.count) file(s) of the model did not arrive")
        }
        for file in artifact.files {
            var info = stat()
            guard lstat(staging.appendingPathComponent(file.path).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, Int64(info.st_size) == file.sizeBytes else {
                throw ClusterModelProvisioningError("\(file.path) is not a single-linked file of its manifest size")
            }
        }
        // Exactly the manifest's files: anything else that appeared in the staging during the copy refuses it.
        let unexpected = unexpectedStagingEntries(partsAllowed: false)
        if !unexpected.isEmpty {
            try? FileManager.default.removeItem(at: staging)
            verified.removeAll()
            let names = unexpected.prefix(3).map { String($0.prefix(80)) }.joined(separator: ", ")
            throw ClusterModelProvisioningError("the staged copy of \(artifact.modelID) holds \(unexpected.count) item(s) besides its manifest's files (\(names)); the copy was discarded")
        }
        let manifest = staging.appendingPathComponent("manifest.json")
        let fd = open(manifest.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ClusterModelProvisioningError("the manifest could not be written") }
        let wrote = artifact.manifest.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        _ = fsync(fd); close(fd)
        guard wrote == artifact.manifest.count else { throw ClusterModelProvisioningError("the manifest could not be written") }
        // This Mac's own worker checks the folder as it will load it (names, configuration, manifest): the catalog digest
        // does not bind file names, so a renamed copy is refused here and never listed as held.
        if let stagedCheck, let refusal = stagedCheck(staging) {
            try? FileManager.default.removeItem(at: staging)
            verified.removeAll()
            throw ClusterModelProvisioningError("this Mac's cluster worker refused the copied \(artifact.modelID) \(artifact.version): \(refusal); the copy was discarded")
        }
        // Exclusive: never replaces what appeared at the destination after `begin` (rename(2) would replace an empty folder).
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw ClusterModelProvisioningError("the model folder could not be put in place (errno \(errno)); \(folder) appeared in this Mac's model store during the copy")
        }
        let parent = open(store.path, O_RDONLY | O_CLOEXEC)
        if parent >= 0 { _ = fsync(parent); close(parent) }
        // Written with the cache off, but macOS may still keep the pages: the next load gate must not see them.
        ClusterModelStore.dropCachedPages(folder: destination)
        return destination
    }

    // MARK: Internals

    /// The staging's entries (relative paths) that are not this manifest's: allowed are each manifest file as a regular
    /// file (with `partsAllowed`, its `.part` too), the folders on the way to one as folders, and `manifest.json`.
    /// Names compare exactly. An allowed name of the wrong kind (a folder where a file belongs) is unexpected; the
    /// contents of an unexpected folder are not listed (it goes, or refuses, as a whole).
    func unexpectedStagingEntries(partsAllowed: Bool) -> [String] {
        var files: Set<String> = ["manifest.json"], folders = Set<String>()
        for file in artifact.files {
            files.insert(file.path)
            if partsAllowed { files.insert(file.path + ".part") }
            var prefix = ""
            for component in file.path.split(separator: "/").dropLast() {
                prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                folders.insert(prefix)
            }
        }
        var unexpected = [String]()
        func walk(_ relative: String) {
            let url = relative.isEmpty ? staging : staging.appendingPathComponent(relative)
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() {
                let path = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard lstat(staging.appendingPathComponent(path).path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFDIR where folders.contains(path): walk(path)
                case S_IFREG where files.contains(path): continue
                default: unexpected.append(path)
                }
            }
        }
        walk("")
        return unexpected
    }

    /// Removes the hidden staging of copies of OTHER artifacts (abandoned: one copy runs at a time on a Mac), so
    /// hidden bytes never starve the disk; this artifact's own staging stays for its resume. True when one went.
    private func reclaimAbandonedStaging() -> Bool {
        let own = staging.lastPathComponent
        var reclaimed = false
        for name in (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []
        where name.hasPrefix(".darkbloom-incoming-") && name != own {
            let url = store.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { reclaimed = true }
        }
        return reclaimed
    }

    private func makeDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
                throw ClusterModelProvisioningError("\(url.lastPathComponent) is not a folder this user owns")
            }
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    }

    /// A staged file that is complete: single-linked regular file of the right size whose digest matches (read uncached).
    private func fileVerified(_ url: URL, _ file: ClusterCatalogArtifact.File) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid() else {
            throw ClusterModelProvisioningError("a staged file of \(file.path) is not a single-linked regular file")
        }
        guard Int64(info.st_size) == file.sizeBytes, let hasher = try? Self.hashUncached(url, length: file.sizeBytes) else { return false }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }

    private func openPart(index: Int, at offset: Int64) throws -> (index: Int, fd: Int32, hasher: SHA256, written: Int64) {
        let file = artifact.files[index]
        let final = staging.appendingPathComponent(file.path)
        try makeDirectory(final.deletingLastPathComponent())
        let part = final.path + ".part"
        let fd = open(part, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ClusterModelProvisioningError("\(file.path) could not be opened for writing (errno \(errno))") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            close(fd); throw ClusterModelProvisioningError("a staged file of \(file.path) is not a single-linked regular file")
        }
        _ = fcntl(fd, F_NOCACHE, 1)
        // Resume: keep exactly `offset` bytes already staged (hash them once, uncached); anything beyond is cut.
        guard Int64(info.st_size) >= offset else { close(fd); throw ClusterModelProvisioningError("\(file.path) resumes past its staged bytes") }
        guard ftruncate(fd, off_t(offset)) == 0, lseek(fd, off_t(offset), SEEK_SET) == off_t(offset) else {
            close(fd); throw ClusterModelProvisioningError("\(file.path) could not be resumed")
        }
        let hasher = offset > 0 ? try Self.hashUncached(URL(fileURLWithPath: part), length: offset) : SHA256()
        return (index, fd, hasher, offset)
    }

    /// SHA-256 of the first `length` bytes, read with the file cache off.
    static func hashUncached(_ url: URL, length: Int64) throws -> SHA256 {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClusterModelProvisioningError("cannot read \(url.lastPathComponent)") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        var left = length
        var buffer = [UInt8](repeating: 0, count: 8 << 20)
        while left > 0 {
            let count = Darwin.read(fd, &buffer, Int(min(Int64(buffer.count), left)))
            if count < 0 { if errno == EINTR { continue }; throw ClusterModelProvisioningError("cannot read \(url.lastPathComponent)") }
            if count == 0 { throw ClusterModelProvisioningError("\(url.lastPathComponent) is shorter than expected") }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            left -= Int64(count)
        }
        return hasher
    }
}

// MARK: - The sending Mac

/// Reads a model's files for a copy with the file cache off, in chunks, and checks each source file is a
/// single-linked regular file of its manifest size before it is sent (the receiver verifies every digest).
public final class ClusterModelSender: @unchecked Sendable {
    public let artifact: ClusterCatalogArtifact
    public let directory: URL
    private var open: (index: Int, fd: Int32)?

    public init(artifact: ClusterCatalogArtifact, directory: URL) throws {
        self.artifact = artifact; self.directory = directory
        for file in artifact.files {
            var info = stat()
            guard lstat(directory.appendingPathComponent(file.path).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  Int64(info.st_size) == file.sizeBytes else {
                throw ClusterModelProvisioningError("this Mac's copy of \(file.path) is missing or not its manifest size")
            }
        }
    }

    deinit { if let open { close(open.fd) } }

    /// Up to `count` bytes of file `index` from `offset`.
    public func read(index: Int, offset: Int64, count: Int) throws -> Data {
        if open?.index != index {
            if let open { close(open.fd) }
            let fd = Darwin.open(directory.appendingPathComponent(artifact.files[index].path).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ClusterModelProvisioningError("cannot read \(artifact.files[index].path)") }
            _ = fcntl(fd, F_NOCACHE, 1)
            open = (index, fd)
        }
        let length = Int(min(Int64(count), artifact.files[index].sizeBytes - offset))
        guard length > 0 else { return Data() }
        var data = Data(count: length)
        var done = 0
        try data.withUnsafeMutableBytes { buffer in
            while done < length {
                let got = pread(open!.fd, buffer.baseAddress! + done, length - done, off_t(offset) + off_t(done))
                if got < 0 { if errno == EINTR { continue }; throw ClusterModelProvisioningError("reading \(artifact.files[index].path) failed") }
                if got == 0 { throw ClusterModelProvisioningError("\(artifact.files[index].path) ended early") }
                done += got
            }
        }
        return data
    }
}

// MARK: - Wire

/// The frames of a copy on the link control channel (inside the pairing-keyed, encrypted session).
public enum ClusterModelTransferWire {
    /// One chunk: file index (UInt32), offset (UInt64), then the bytes.
    public static func chunk(index: Int, offset: Int64, _ bytes: Data) -> Data {
        var header = Data(count: 12)
        header.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(index).bigEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt64(offset).bigEndian, toByteOffset: 4, as: UInt64.self)
        }
        return header + bytes
    }

    public static func parseChunk(_ data: Data) -> (index: Int, offset: Int64, bytes: Data)? {
        guard data.count >= 12 else { return nil }
        let start = data.startIndex
        var index: UInt32 = 0, offset: UInt64 = 0
        for byte in data[start..<start + 4] { index = index << 8 | UInt32(byte) }
        for byte in data[start + 4..<start + 12] { offset = offset << 8 | UInt64(byte) }
        guard offset <= UInt64(Int64.max) else { return nil }
        return (Int(index), Int64(offset), data[(start + 12)...])
    }
}


// MARK: - Trust

/// Which artifacts a Mac accepts from another Mac. A copy is accepted only when this build's own qualification records
/// (the only per-model data; a pair serves nothing they do not grant) pin its exact aggregate digest, so a paired peer
/// can never place a self-consistent manifest of other files, under any model name, in this Mac's store; every file is
/// then verified against that pinned identity as it arrives. A protected build (one the catalog marks with required
/// runtime capabilities) keeps its own words. The records are passed in, so this stays pure.
public enum ClusterModelCopyTrust {
    public static func refusal(_ artifact: ClusterCatalogArtifact, pinnedArtifacts: Set<String>, protected: Bool) -> String? {
        if pinnedArtifacts.contains(artifact.aggregateSHA256) { return nil }
        let digest = String(artifact.aggregateSHA256.prefix(12))
        if protected {
            return "\(artifact.modelID) is a protected build, and this build's qualification records do not pin the offered digest \(digest)…; it was not accepted"
        }
        return "\(artifact.modelID) \(artifact.version) is not one this build's cluster runtime serves (its qualification records do not pin the offered digest \(digest)…); it was not accepted"
    }
}

// MARK: - Single-Mac models in the cluster store

extension ClusterModelStore {
    /// Clones a model folder's files (APFS clones: no new blocks, each file single-linked) into `store` under its
    /// folder name, with its manifest; nil when the store holds it already. Each call stages under its own hidden name
    /// and the rename into place is exclusive, so two processes cloning at once (the onboarding and the cluster
    /// service) never delete or mix each other's files: the folder appears whole, once, or not at all.
    public static func cloneFolder(artifact: ClusterCatalogArtifact, from directory: URL, into store: URL) throws -> String? {
        if case .complete = holding(store: store, artifact: artifact) { return nil }
        let folder = artifact.folderName
        let destination = store.appendingPathComponent(folder)
        var existing = stat()
        guard lstat(destination.path, &existing) != 0 else { return nil }
        let prefix = ".darkbloom-clone-" + String(artifact.aggregateSHA256.prefix(32)) + "-"
        sweepStaleClones(store: store, prefix: ".darkbloom-clone-")
        let staging = store.appendingPathComponent(prefix + "\(getpid())-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in artifact.files {
                let target = staging.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                var info = stat()
                let source = directory.appendingPathComponent(file.path)
                guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int64(info.st_size) == file.sizeBytes else {
                    throw ClusterModelProvisioningError("the source's \(file.path) is missing or not its manifest size")
                }
                guard clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
                    throw ClusterModelProvisioningError("\(file.path) could not be cloned into the cluster's model store (errno \(errno)); the cluster store must be on the same disk as the product's models")
                }
            }
            let manifest = staging.appendingPathComponent("manifest.json")
            let fd = open(manifest.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw ClusterModelProvisioningError("the manifest could not be written") }
            let wrote = artifact.manifest.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            _ = fsync(fd); close(fd)
            guard wrote == artifact.manifest.count else { throw ClusterModelProvisioningError("the manifest could not be written") }
            guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                let raced = errno == EEXIST
                try? FileManager.default.removeItem(at: staging)
                if raced { return nil }   // another process placed it first
                throw ClusterModelProvisioningError("the cloned folder could not be put in place (errno \(errno))")
            }
            return folder
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Clone staging an ended process left (older than an hour; clones hold no new blocks until their source goes).
    static func sweepStaleClones(store: URL, prefix: String) {
        let cutoff = Date().addingTimeInterval(-3600)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? [] where name.hasPrefix(prefix) {
            let url = store.appendingPathComponent(name)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
                  Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
