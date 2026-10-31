import CryptoKit
import DarkbloomClusterPlacement
import Foundation
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
@_spi(OwnerService) import DarkbloomClusterRemote

/// Private installed metadata quotation. Its result cannot enable serving,
/// establish payload custody, or replace the two-rank calibration experiment.
public enum GLM5NextCalibrationInstalledQuote {
    struct Input: Codable {
        let schema: String
        let clusterID: String
        let peerPin: String
        let peerBinarySHA256: String
        let request: GLM5NextCalibrationQuoteDocument.Request
        let modelDirectory: String
        let environment: [String: String]
    }

    /// Retained by Prepared and the process pump through actual child exit,
    /// including when a caller's wait expires before the child is reaped.
    private final class Resources {
        private var device: ClusterDeviceLease?
        var document: URL?
        init(device: ClusterDeviceLease) { self.device = device }
        func record(clusterID: String, peerID: String, rank: Int, epoch: UUID, requestID: UUID) throws {
            guard let device else { throw GLM5NextCalibrationDocument.invalid("Quotation lease was retired") }
            try device.record(clusterID: clusterID, peerID: peerID, rank: rank,
                membershipEpoch: epoch, leaseID: requestID, ownerIncarnation: UUID(), nativeLaunchID: UUID())
        }
        // Called only after actual child exit or proven launch failure. Clearing
        // the reference releases flock even while the process/preflight retains
        // this Resources object for its final pump cleanup.
        func resolveAndRelease() throws {
            guard let lease = device else { throw GLM5NextCalibrationDocument.invalid("Quotation lease was retired") }
            try lease.resolve()
            device = nil
            if let document {
                do {
                    try FileManager.default.removeItem(at: document)
                    self.document = nil
                } catch {
                    // Preserve the exact owned path for the existing deinit retry.
                }
            }
        }
        deinit { if let document { try? FileManager.default.removeItem(at: document) } }
    }

    /// Retained metadata evidence, not a payload receipt, native-start grant or
    /// serving capability. Only the actual installed quotation path can mint it.
    struct Completed {
        let authorized: GLM5NextCalibrationQuoteAuthorizer.Authorized
        let response: GLM5NextCalibrationQuoteDocument.Response
        let responseData: Data
        let pair: GLM5NextCalibrationInstalledPair
        let installedExecutable: URL
        let worker: URL
        let metallib: URL
        let modelDirectory: URL
        let environment: [String: String]
        let pinnedVocabularySize: Int
        private let fileIdentities: [DistributedInstalledFiles.Identity]

        fileprivate init(authorized: GLM5NextCalibrationQuoteAuthorizer.Authorized,
                         response: GLM5NextCalibrationQuoteDocument.Response, responseData: Data,
                         pair: GLM5NextCalibrationInstalledPair, installedExecutable: URL,
                         worker: URL, metallib: URL, modelDirectory: URL,
                         environment: [String: String], pinnedVocabularySize: Int,
                         fileIdentities: [DistributedInstalledFiles.Identity]) {
            self.authorized = authorized; self.response = response; self.responseData = responseData
            self.pair = pair; self.installedExecutable = installedExecutable
            self.worker = worker; self.metallib = metallib; self.modelDirectory = modelDirectory
            self.environment = environment; self.pinnedVocabularySize = pinnedVocabularySize
            self.fileIdentities = fileIdentities
        }

        /// The finite owner must freshly acquire exclusion and supply its own
        /// bounded deadline. No quotation deadline, closure, document, process,
        /// Prepared object or metadata device lease is retained here.
        func requireUnchanged(deadline: UInt64) throws {
            try DistributedInstalledFiles.check(deadline)
            let request = authorized.request, p = request.selection
            let nowUnix = Int64(Date().timeIntervalSince1970)
            try GLM5NextCalibrationQuoteDocument.validate(request, identity: authorized.identity,
                rank: p.rank, now: nowUnix, appSHA256: request.appSHA256,
                peerIdentitySHA256: request.peerIdentitySHA256)
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now, deadline - now <= ClusterWorkerLimits.deadlineNanoseconds,
                  deadline - now <= UInt64(p.expiresUnixSeconds - nowUnix) * 1_000_000_000 else {
                throw GLM5NextCalibrationDocument.invalid("Finite preparation deadline exceeds retained quote scope")
            }
            try pair.requireUnchanged()
            for file in fileIdentities {
                try DistributedInstalledFiles.check(deadline)
                try file.requireUnchanged()
            }
            try DistributedInstalledFiles.check(deadline)
        }
    }

    public static func run(input: URL, installedExecutable: URL) throws -> Data {
        try complete(input: input, installedExecutable: installedExecutable).responseData
    }

    static func complete(input: URL, installedExecutable: URL,
                         placement: GLM5NextCalibrationPlacement.Selection? = nil) throws -> Completed {
        let paths = try ClusterUserPaths()
        return try complete(input: input, installedExecutable: installedExecutable,
            deviceDirectory: paths.deviceDirectory, placement: placement,
            loadPair: { try GLM5NextCalibrationInstalledPair.load(clusterID: $0, peerPin: $1) })
    }

    /// Internal environment-only test seam: still verifies actual installed
    /// files, signs with a validated explicit pair, spawns/reaps the real child,
    /// and strictly validates its response. Never accepts an injected Response.
    static func complete(input: URL, installedExecutable: URL, deviceDirectory: URL,
                         placement: GLM5NextCalibrationPlacement.Selection? = nil,
                         quoteTimeoutNanoseconds: UInt64 = 300_000_000_000,
                         loadPair: (String, String) throws -> GLM5NextCalibrationInstalledPair) throws -> Completed {
        guard quoteTimeoutNanoseconds > 0, quoteTimeoutNanoseconds <= 300_000_000_000 else {
            throw GLM5NextCalibrationDocument.invalid("Quotation timeout exceeds its existing bound")
        }
        let data = try ClusterConfigurationFiles.read(input, maximum: 256 << 10, privateMode: true)
        try placement?.requireCurrent(input: data)
        let selectedData = try placement.map { try ClusterGLMCalibrationPlacement.selecting(cut: $0.decision.cut, in: data) } ?? data
        let selection = try JSONDecoder().decode(Input.self, from: selectedData)
        guard selection.schema == "darkbloom_glm_calibration_quote_input_v1",
              ClusterConfigurationSyntax.hash(selection.peerBinarySHA256),
              installedExecutable.lastPathComponent == BuildEnvironment.current.cliName,
              installedExecutable.deletingLastPathComponent().lastPathComponent == "MacOS",
              installedExecutable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents",
              installedExecutable.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent == BuildEnvironment.current.appBundleName else {
            throw GLM5NextCalibrationDocument.invalid("Expected the installed app and a bounded quotation selection")
        }
        let pair = try loadPair(selection.clusterID, selection.peerPin)
        guard pair.clusterID == selection.clusterID,
              ClusterMemberPin.of(uncompressedKey: pair.peerIdentity) == selection.peerPin else {
            throw GLM5NextCalibrationDocument.invalid("Loaded pair differs from explicit quotation selection")
        }
        let pins = [ClusterMemberPin.of(uncompressedKey: pair.localIdentity), selection.peerPin].sorted()
        guard let rank = pins.firstIndex(of: ClusterMemberPin.of(uncompressedKey: pair.localIdentity)) else {
            throw GLM5NextCalibrationDocument.invalid("Installed member has no rank")
        }
        let p = selection.request.selection
        guard p.rank == rank else { throw GLM5NextCalibrationDocument.invalid("Quotation rank differs from the installed pair") }
        let nowUnix = Int64(Date().timeIntervalSince1970), nowUptime = DispatchTime.now().uptimeNanoseconds
        guard p.expiresUnixSeconds > nowUnix + 1 else { throw GLM5NextCalibrationDocument.invalid("Quotation selection expired") }
        let deadline = nowUptime + min(quoteTimeoutNanoseconds,
            UInt64(min(300, p.expiresUnixSeconds - nowUnix - 1)) * 1_000_000_000)
        let helper = installedExecutable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/darkbloom-cluster-worker")
        let metallib = helper.deletingLastPathComponent().appendingPathComponent("mlx.metallib")
        let model = URL(fileURLWithPath: selection.modelDirectory, isDirectory: true)
        try ClusterConfigurationFiles.requireAbsolute(selection.modelDirectory)
        let inputFile = try DistributedInstalledFiles.verify(input, expectedSHA256: hash(data),
            maximumBytes: 256 << 10, deadline: deadline)
        let files = try [
            DistributedInstalledFiles.verify(installedExecutable, expectedSHA256: selection.request.appSHA256,
                maximumBytes: 256 << 20, executable: true, deadline: deadline),
            DistributedInstalledFiles.verify(helper, expectedSHA256: p.environment.binarySHA256,
                maximumBytes: 256 << 20, executable: true, deadline: deadline),
            DistributedInstalledFiles.verify(metallib, expectedSHA256: p.environment.metallibSHA256,
                maximumBytes: 256 << 20, deadline: deadline)
        ] + ["config.json", "model.safetensors.index.json"].map { name in
            guard let file = p.files[name] else { throw GLM5NextCalibrationDocument.invalid("Quotation metadata is missing") }
            return try DistributedInstalledFiles.verify(model.appendingPathComponent(name),
                expectedSHA256: file.sha256, maximumBytes: 32 << 20, deadline: deadline)
        }
        try ClusterConfigurationFiles.ensureDirectory(deviceDirectory, create: true, privateMode: true)
        let resources = try Resources(device: ClusterDeviceLease(directoryURL: deviceDirectory))
        let currentSelection = {
            try placement?.requireCurrent(input: data)
            try pair.requireUnchanged()
            try inputFile.requireUnchanged()
            for file in files { try file.requireUnchanged() }
            try DistributedInstalledFiles.check(deadline)
            withExtendedLifetime(resources) {}
        }
        let peers = pins.enumerated().map { index, pin in
            ClusterWorkerPeer(id: ClusterSetupMemberFacts.memberID(pin: pin),
                buildSHA256: index == rank ? p.environment.binarySHA256 : selection.peerBinarySHA256)
        }
        let identity = ClusterWorkerIdentity(membershipEpoch: p.epoch, modelID: GLM5NextCalibrationDocument.modelID,
            artifactSHA256: p.artifactSHA256, configurationSHA256: p.files["config.json"]!.sha256, peers: peers)
        let authorized = try GLM5NextCalibrationQuoteAuthorizer.authorize(selection.request, identity: identity,
            rank: rank, now: Int64(Date().timeIntervalSince1970), memberIdentity: pair.localIdentity,
            peerIdentity: pair.peerIdentity, appSHA256: selection.request.appSHA256,
            signer: pair.signer, verifySelection: currentSelection)
        let directory = deviceDirectory.appendingPathComponent("glm-calibration", isDirectory: true)
        try ClusterConfigurationFiles.ensureDirectory(directory, create: true, privateMode: true)
        let document = try GLM5NextCalibrationQuoteAuthorizer.write(authorized, directory: directory,
            now: Int64(Date().timeIntervalSince1970))
        resources.document = document
        let prepared = try GLM5NextCalibrationQuoteLaunch.prepare(authorized: authorized, document: document,
            installedApp: installedExecutable, worker: helper, metallib: metallib, modelDirectory: model,
            environment: selection.environment, deadline: deadline, nowUptime: DispatchTime.now().uptimeNanoseconds,
            nowUnix: Int64(Date().timeIntervalSince1970), requireCurrentSelection: currentSelection)
        let process = try GLM5NextCalibrationQuoteProcess(prepared: prepared)
        try resources.record(clusterID: pair.clusterID, peerID: peers[rank].id, rank: rank,
            epoch: p.epoch, requestID: selection.request.authorization.requestID)
        do { try process.start() }
        catch {
            // start() throws only before a child is successfully launched.
            try resources.resolveAndRelease()
            throw error
        }
        guard process.waitUntilExited(deadline: deadline + 3_000_000_000) else {
            process.cancel()
            throw GLM5NextCalibrationDocument.invalid("Quotation child exit remains unobserved; ownership is retained")
        }
        let response: Data
        do { response = try process.response() }
        catch {
            try resources.resolveAndRelease() // Actual exit was observed, including a failed exit.
            // The source-matched metadata worker emits no prompts or credentials.
            // Keep its already-bounded diagnostic useful to this private caller.
            let diagnostic = String(decoding: process.diagnosticTail, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GLM5NextCalibrationDocument.invalid("Quotation child failed (\(error))"
                + (diagnostic.isEmpty ? "" : ": \(diagnostic)"))
        }
        try resources.resolveAndRelease()
        try currentSelection()
        let vocabularySize = try GLM5NextCalibrationBinding.configurationVocabulary(
            at: model.appendingPathComponent("config.json"), expectedSHA256: identity.configurationSHA256, deadline: deadline)
        try currentSelection()
        let validated = try GLM5NextCalibrationQuoteAuthorizer.validateResponse(response, authorized: authorized,
            now: Int64(Date().timeIntervalSince1970), expectedVocabularySize: vocabularySize)
        return Completed(authorized: authorized, response: validated, responseData: response,
            pair: pair, installedExecutable: installedExecutable, worker: helper, metallib: metallib,
            modelDirectory: model, environment: selection.environment, pinnedVocabularySize: vocabularySize,
            // The signed request/selected environment are retained as values.
            // Its transient input file and the retired quote document may go away.
            fileIdentities: files)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
