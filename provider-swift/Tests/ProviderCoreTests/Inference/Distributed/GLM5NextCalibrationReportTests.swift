import CryptoKit
import Darwin
import Foundation
import Testing
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
@testable import ProviderCore

/// Private, uncompiled regression draft. Uses the existing actual authorizer
/// fixtures and the actual process supervisor; shell children only emit supplied
/// synthetic wire records. This proves no native/GPU/model behavior.
/// Consumes opaque Completed only, minted via Hume's actual-child fixture.
/// Synthetic child claims remain explicitly distinct from real native plans.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_INPUT"] != nil
    || ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_BINDING_REQUIRED"] == "1"))
struct GLM5NextCalibrationReportTests {
    typealias D = GLM5NextCalibrationDocument
    typealias Q = GLM5NextCalibrationQuoteDocument
    typealias A = GLM5NextCalibrationQuoteAuthorizer
    typealias R = GLM5NextCalibrationReport

    final class Fixture {
        typealias C = GLM5NextCalibrationInstalledQuote
        let installed: GLM5NextCalibrationInstalledQuoteCompletedTests.Fixture
        let localSigner: GLM5NextCalibrationAuthorizerTests.Signer
        let quotation: C.Completed
        let authorized: GLM5NextCalibrationAuthorizer.Authorized

        init(rank: Int = 0, promptCount: Int = 2) throws {
            let f = try GLM5NextCalibrationInstalledQuoteCompletedTests.Fixture()
            installed = f
            let keys = [f.pairing.local, f.pairing.peer].sorted {
                ClusterMemberPin.of(uncompressedKey: $0.key.publicKey.x963Representation)
                    < ClusterMemberPin.of(uncompressedKey: $1.key.publicKey.x963Representation)
            }
            let local = keys[rank], remote = keys[1 - rank]
            localSigner = local
            let localPin = ClusterMemberPin.of(uncompressedKey: local.key.publicKey.x963Representation)
            let peerPin = ClusterMemberPin.of(uncompressedKey: remote.key.publicKey.x963Representation)
            // Orient the same genuinely signed two-key roster deterministically;
            // no retry-until-random-rank, fabricated Completed, or Response seam.
            var records = try #require(JSONSerialization.jsonObject(
                with: Data(contentsOf: f.pairing.store.recordsFile)) as? [String: Any])
            let pairings = try #require(records["pairings"] as? [[String: Any]])
            var selected = try #require(pairings.first { ($0["peerPin"] as? String) == f.pairing.peerPin })
            selected["peerPin"] = peerPin
            selected["peerIdentityKey"] = remote.key.publicKey.x963Representation.base64EncodedString()
            records["localPin"] = localPin
            records["localIdentityKey"] = local.key.publicKey.x963Representation.base64EncodedString()
            records["pairings"] = [selected]
            try JSONSerialization.data(withJSONObject: records, options: .sortedKeys)
                .write(to: f.pairing.store.recordsFile)
            var input = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.input)) as? [String: Any])
            input["peerPin"] = peerPin
            var request = try #require(input["request"] as? [String: Any])
            let peerHash = GLM5NextCalibrationLaunch.peerFingerprint(remote.key.publicKey.x963Representation)
            request["peerIdentitySHA256"] = peerHash
            var environment = try #require(input["environment"] as? [String: String])
            environment["JACCL_RANK"] = String(rank)
            environment[GLM5NextCalibrationLaunch.peerIdentityVariable] = peerHash
            input["environment"] = environment
            var selection = try #require(request["selection"] as? [String: Any])
            selection["rank"] = rank
            if promptCount != 2 {
                // The schema-emitting child mirrors this selected scope; this is
                // not a claim that a native GLM plan was produced by the fixture.
                selection["maximumPromptTokens"] = promptCount
                selection["maximumContextTokens"] = promptCount + 2
                var authorization = try #require(request["authorization"] as? [String: Any])
                authorization["promptTokenIDs"] = Array(repeating: 1, count: promptCount)
                request["authorization"] = authorization
            }
            var facts = try #require(selection["environment"] as? [String: Any])
            facts["variableSHA256"] = environment.filter {
                $0.key.hasPrefix("MLX_") || $0.key.hasPrefix("DARKBLOOM_")
            }.mapValues(GLM5NextCalibrationLaunch.digest)
            selection["environment"] = facts; request["selection"] = selection; input["request"] = request
            try JSONSerialization.data(withJSONObject: input, options: .sortedKeys).write(to: f.input)
            let completed = try C.complete(input: f.input, installedExecutable: f.app, deviceDirectory: f.device,
                quoteTimeoutNanoseconds: f.timeout, loadPair: { cluster, pin in
                    try GLM5NextCalibrationInstalledPair.load(clusterID: cluster, peerPin: pin,
                        store: f.pairing.store, loadSigner: { local })
                })
            quotation = completed
            #expect(completed.authorized.request.selection.rank == rank)
            let body = try A.experimentBody(response: completed.responseData, authorized: completed.authorized,
                now: Int64(Date().timeIntervalSince1970), expectedVocabularySize: completed.pinnedVocabularySize)
            authorized = try Self.sign(body, completed: completed)
        }

        static func sign(_ body: D.Body, completed: C.Completed) throws -> GLM5NextCalibrationAuthorizer.Authorized {
            try GLM5NextCalibrationAuthorizer.authorize(body, identity: completed.authorized.identity,
                rank: body.selection.rank, now: Int64(Date().timeIntervalSince1970),
                expectedVocabularySize: completed.pinnedVocabularySize,
                memberIdentity: completed.pair.localIdentity, peerIdentity: completed.pair.peerIdentity,
                appSHA256: completed.authorized.request.appSHA256, signer: completed.pair.signer,
                verifySelection: { try completed.requireUnchanged(deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000) })
        }

        func changedQuote(_ change: String) throws -> C.Completed {
            let f = installed
            var input = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.input)) as? [String: Any])
            var request = try #require(input["request"] as? [String: Any])
            request["quoteRequestID"] = UUID().uuidString
            var selection = try #require(request["selection"] as? [String: Any])
            var authorization = try #require(request["authorization"] as? [String: Any])
            switch change {
            case "request": authorization["requestID"] = UUID().uuidString
            case "prompt": authorization["promptTokenIDs"] = [2, 1]
            case "expiry": selection["expiresUnixSeconds"] = quotation.authorized.request.selection.expiresUnixSeconds - 1
            case "budget": authorization["nativeHardCapBytes"] = 2400
            default: Issue.record("Unknown quote mutation")
            }
            request["selection"] = selection; request["authorization"] = authorization; input["request"] = request
            try JSONSerialization.data(withJSONObject: input, options: .sortedKeys).write(to: f.input)
            return try C.complete(input: f.input, installedExecutable: f.app, deviceDirectory: f.device,
                quoteTimeoutNanoseconds: f.timeout, loadPair: { cluster, pin in
                    try GLM5NextCalibrationInstalledPair.load(clusterID: cluster, peerPin: pin,
                        store: f.pairing.store, loadSigner: { self.localSigner })
                })
        }

        func object() throws -> [String: Any] {
            let a = authorized.body.authorization, p = authorized.body.selection, q = quotation.response
            let signed = try JSONDecoder().decode(D.SignedDocument.self, from: authorized.document)
            let digest = SHA256.hash(data: signed.payload).map { String(format: "%02x", $0) }.joined()
            let phases = ["before-load", "loaded"]
                + Array(repeating: "committed-token", count: p.rank == 0 ? a.outputCount : 0)
                + ["request-finished"]
            return ["nativeHardCapBytes": a.nativeHardCapBytes, "hostBudgetBytes": a.hostBudgetBytes,
                "osHeadroomBytes": a.osHeadroomBytes,
                "committedTokens": a.promptTokenIDs.count + a.outputCount - 1,
                "qualifiesMaximumEnvelope": false, "requiresProcessExit": true,
                "observations": phases.map { ["phase": $0, "nativeActiveBytes": 10, "nativePeakBytes": 20,
                    "host": ["mallocBytes": 10, "processFootprintBytes": 100]] as [String: Any] },
                "quote": ["authorizationSHA256": digest, "descriptorSHA256": q.descriptorSHA256,
                    "cut": q.cut, "rank": q.rank, "nativeBytes": q.nativeBytes, "hostBytes": q.hostBytes,
                    "loadCapacityBytes": q.loadCapacityBytes, "requestCapacityBytes": q.requestCapacityBytes,
                    "inventorySHA256": q.inventorySHA256, "configurationSHA256": q.normalizedConfigurationSHA256,
                    "numericalPolicySHA256": q.numericalPolicySHA256,
                    "executionEnvironmentSHA256": q.executionEnvironmentSHA256,
                    "qualifiesMaximumEnvelope": false]]
        }
        func validate(_ object: [String: Any]) throws -> R.Report {
            try R.validate(JSONSerialization.data(withJSONObject: object), authorized: authorized, quotation: quotation)
        }
    }

    @Test(arguments: [0, 1])
    func validReportsUseNativeFrontierAndRankLocalSamples(rank: Int) throws {
        let f = try Fixture(rank: rank)
        let a = f.authorized.body.authorization
        #expect(a.promptTokenIDs.count == 2 && a.outputCount == 2)
        let result = try f.validate(f.object())
        #expect(result.committedTokens == 3) // 2 prompt positions plus 1 decode forward.
        #expect(result.observations.map(\.phase) == (rank == 0
            ? ["before-load", "loaded", "committed-token", "committed-token", "request-finished"]
            : ["before-load", "loaded", "request-finished"]))
    }

    @Test(arguments: ["output-as-frontier", "missing-token-sample", "reordered-phases", "extra-phase",
        "qualified", "no-exit", "authority", "raw-config", "descriptor", "inventory", "environment",
        "native-over-cap", "host-over-budget", "os-headroom", "baseline-overflow", "negative-host",
        "unknown-root", "unknown-quote", "unknown-observation", "unknown-host", "boolean-integer"])
    func alteredContentIsRefused(change: String) throws {
        let f = try Fixture(), a = f.authorized.body.authorization
        var object = try f.object(), quote = try #require(object["quote"] as? [String: Any])
        var observations = try #require(object["observations"] as? [[String: Any]])
        switch change {
        case "output-as-frontier": object["committedTokens"] = a.outputCount
        case "missing-token-sample": observations.remove(at: 2)
        case "reordered-phases": observations.swapAt(0, 1)
        case "extra-phase": observations.append(observations[0])
        case "qualified": object["qualifiesMaximumEnvelope"] = true
        case "no-exit": object["requiresProcessExit"] = false
        case "authority": quote["authorizationSHA256"] = String(repeating: "0", count: 64)
        case "raw-config": quote["configurationSHA256"] = f.authorized.identity.configurationSHA256
        case "descriptor": quote["descriptorSHA256"] = String(repeating: "0", count: 64)
        case "inventory": quote["inventorySHA256"] = String(repeating: "0", count: 64)
        case "environment": quote["executionEnvironmentSHA256"] = String(repeating: "0", count: 64)
        case "native-over-cap": observations[1]["nativeActiveBytes"] = a.nativeHardCapBytes + 1
        case "host-over-budget", "os-headroom", "baseline-overflow", "negative-host", "unknown-host":
            let index = change == "baseline-overflow" ? 0 : 1
            var host = try #require(observations[index]["host"] as? [String: Any])
            switch change {
            case "host-over-budget": host["mallocBytes"] = 10 + a.hostBudgetBytes + 1
            case "os-headroom": host["processFootprintBytes"] = f.authorized.body.selection.environment.memoryBytes - a.osHeadroomBytes + 1
            case "baseline-overflow": host["processFootprintBytes"] = Int.max
            case "negative-host": host["mallocBytes"] = -1
            default: host["extra"] = true
            }
            observations[index]["host"] = host
        case "unknown-root": object["ready"] = true
        case "unknown-quote": quote["extra"] = true
        case "unknown-observation": observations[1]["extra"] = true
        case "boolean-integer": object["committedTokens"] = true
        default: Issue.record("Unknown regression mutation")
        }
        object["quote"] = quote; object["observations"] = observations
        #expect(throws: (any Error).self) { try f.validate(object) }
    }

    @Test func rankOneCannotInventOwnerTokenSamples() throws {
        let f = try Fixture(rank: 1)
        var object = try f.object(), observations = try #require(object["observations"] as? [[String: Any]])
        var sample = observations[1]; sample["phase"] = "committed-token"
        observations.insert(sample, at: 2); object["observations"] = observations
        #expect(throws: (any Error).self) { try f.validate(object) }
    }

    @Test func payloadBoundsRemainExact() throws {
        let f = try Fixture()
        for bytes in [Data(), Data(repeating: 32, count: 65_537)] {
            #expect(throws: (any Error).self) {
                try R.validate(bytes, authorized: f.authorized, quotation: f.quotation)
            }
        }
    }

    /// Real pipe output may be provisionally accepted while the direct child is
    /// alive. Completion must fail then and succeed only after observed exit0.
    @Test func reportBeforeExitIsNotCompletion() throws {
        let f = try Fixture(), process = try ProcessFixture(fixture: f, wait: true)
        defer { process.cleanup() }
        try process.child.launch()
        try process.wait { process.child.provisionalReport != nil }
        #expect(!process.child.observedExit)
        #expect(throws: (any Error).self) {
            try R.completed(child: process.child, authorized: f.authorized, quotation: f.quotation)
        }
        try process.release()
        #expect(process.child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000))
        #expect(process.child.termination == .exited(0))
        #expect(try R.completed(child: process.child, authorized: f.authorized, quotation: f.quotation).committedTokens == 3)
    }

    @Test(arguments: ["profile", "profile-id", "prompt-limit", "output-limit", "chunk-limit",
        "context-limit", "identity", "plan", "nonzero"])
    func actualChildBindingAndExitMustMatch(change: String) throws {
        let f = try Fixture(), process = try ProcessFixture(fixture: f, wait: false, change: change)
        defer { process.cleanup() }
        try process.child.launch()
        #expect(process.child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000))
        if change != "nonzero" {
            #expect(process.child.termination == .exited(0))
            #expect(try !process.child.successfulReport().isEmpty) // Detailed binding, not transport, refuses it.
        }
        #expect(throws: (any Error).self) {
            try R.completed(child: process.child, authorized: f.authorized, quotation: f.quotation)
        }
    }

    @Test(arguments: ["request", "prompt", "expiry", "budget"])
    func differentCompletedFromSameActualPairCannotValidateExperiment(change: String) throws {
        let f = try Fixture(), different = try f.changedQuote(change)
        #expect(different.authorized.identity == f.quotation.authorized.identity)
        #expect(different.response.binding == f.quotation.response.binding)
        #expect(different.response.quoteRequestSHA256 != f.quotation.response.quoteRequestSHA256)
        let bytes = try JSONSerialization.data(withJSONObject: f.object())
        #expect(throws: (any Error).self) {
            try R.validate(bytes, authorized: f.authorized, quotation: different)
        }
    }

    @Test(arguments: ["profile", "plan"])
    func validlySignedDifferentBindingCannotBorrowCompleted(change: String) throws {
        let f = try Fixture()
        var body = try #require(JSONSerialization.jsonObject(with: Q.canonical(f.authorized.body)) as? [String: Any])
        var binding = try #require(body["binding"] as? [String: Any])
        if change == "plan" { binding["executionPlanSHA256"] = String(repeating: "f", count: 64) }
        else {
            var profile = try #require(binding["profile"] as? [String: Any])
            profile["id"] = "different-signed-profile"; binding["profile"] = profile
            var selection = try #require(body["selection"] as? [String: Any])
            selection["profileID"] = "different-signed-profile"; body["selection"] = selection
        }
        body["binding"] = binding
        let typed = try JSONDecoder().decode(D.Body.self, from: JSONSerialization.data(withJSONObject: body))
        let signed = try Fixture.sign(typed, completed: f.quotation)
        var report = try f.object(), quote = try #require(report["quote"] as? [String: Any])
        let envelope = try JSONDecoder().decode(D.SignedDocument.self, from: signed.document)
        quote["authorizationSHA256"] = SHA256.hash(data: envelope.payload).map { String(format: "%02x", $0) }.joined()
        report["quote"] = quote // Keep report hash correctly bound: only the Completed/binding comparison refuses.
        #expect(throws: (any Error).self) {
            try R.validate(JSONSerialization.data(withJSONObject: report), authorized: signed, quotation: f.quotation)
        }
    }

    @Test(arguments: [0, 1])
    func actualExitAcceptsPromptFrontierBeyondOutputLimit(rank: Int) throws {
        let f = try Fixture(rank: rank, promptCount: 16)
        #expect(f.authorized.body.authorization.promptTokenIDs.count == 16)
        #expect(f.authorized.body.authorization.outputCount == 2)
        let process = try ProcessFixture(fixture: f, wait: false)
        defer { process.cleanup() }
        try process.child.launch()
        #expect(process.child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000))
        #expect(process.child.termination == .exited(0))
        #expect(try !process.child.successfulReport().isEmpty)
        let result = try R.completed(child: process.child, authorized: f.authorized, quotation: f.quotation)
        #expect(result.committedTokens == 17)
        #expect(result.observations.count == (rank == 0 ? 5 : 3))
    }

    @Test(arguments: ["file-bytes", "device", "memory", "quantum", "overhead"])
    func validlySignedDifferentSelectionCannotBorrowCompleted(change: String) throws {
        let f = try Fixture()
        var body = try #require(JSONSerialization.jsonObject(with: Q.canonical(f.authorized.body)) as? [String: Any])
        var selection = try #require(body["selection"] as? [String: Any])
        switch change {
        case "file-bytes":
            var files = try #require(selection["files"] as? [String: Any])
            var file = try #require(files["config.json"] as? [String: Any])
            file["bytes"] = try #require(file["bytes"] as? Int) + 1
            files["config.json"] = file; selection["files"] = files
        case "device", "memory":
            var environment = try #require(selection["environment"] as? [String: Any])
            let field = change == "device" ? "deviceRegistryID" : "memoryBytes"
            environment[field] = try #require(environment[field] as? Int) + 1
            selection["environment"] = environment
        case "quantum": selection["hostAllocationQuantum"] = f.authorized.body.selection.hostAllocationQuantum + 1
        case "overhead": selection["hostAllocationOverhead"] = f.authorized.body.selection.hostAllocationOverhead + 1
        default: Issue.record("Unknown selection mutation")
        }
        body["selection"] = selection
        let typed = try JSONDecoder().decode(D.Body.self, from: JSONSerialization.data(withJSONObject: body))
        // Admission/signing must succeed first; no invalid-authority false positive.
        let signed = try Fixture.sign(typed, completed: f.quotation)
        #expect(signed.body.binding == f.authorized.body.binding)
        var report = try f.object(), quote = try #require(report["quote"] as? [String: Any])
        let envelope = try JSONDecoder().decode(D.SignedDocument.self, from: signed.document)
        quote["authorizationSHA256"] = SHA256.hash(data: envelope.payload).map { String(format: "%02x", $0) }.joined()
        report["quote"] = quote
        #expect(throws: (any Error).self) {
            try R.validate(JSONSerialization.data(withJSONObject: report), authorized: signed, quotation: f.quotation)
        }
    }

    final class ProcessFixture {
        let root: URL, releaseFile: URL
        let child: ClusterCalibrationProcess
        init(fixture f: Fixture, wait: Bool, change: String = "") throws {
            var canonical = [CChar](repeating: 0, count: Int(PATH_MAX))
            try #require(realpath(NSTemporaryDirectory(), &canonical) != nil)
            root = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            releaseFile = root.appendingPathComponent("release")
            let file = root.appendingPathComponent("report.json")
            try JSONSerialization.data(withJSONObject: f.object()).write(to: file, options: .withoutOverwriting)
            let signed = try JSONDecoder().decode(D.SignedDocument.self, from: f.authorized.document)
            let digest = SHA256.hash(data: signed.payload).map { String(format: "%02x", $0) }.joined()
            let bound = f.authorized.body.binding
            let p = bound.profile
            let profile = ClusterWorkerProfile(id: change == "profile-id" ? p.id + "-other" : p.id,
                vocabularySize: p.vocabularySize + (change == "profile" ? 1 : 0),
                maximumPromptTokens: p.maximumPromptTokens + (change == "prompt-limit" ? 1 : 0),
                maximumOutputTokens: p.maximumOutputTokens + (change == "output-limit" ? 1 : 0),
                maximumChunkTokens: p.maximumChunkTokens + (change == "chunk-limit" ? 1 : 0),
                maximumContextTokens: p.maximumContextTokens + (change == "context-limit" ? 1 : 0))
            let expected = f.authorized.identity
            let identity = change == "identity" ? ClusterWorkerIdentity(membershipEpoch: expected.membershipEpoch,
                modelID: expected.modelID + "-other", artifactSHA256: expected.artifactSHA256,
                configurationSHA256: expected.configurationSHA256, peers: expected.peers) : expected
            let end = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            let script = #"IFS= read -r credential || exit 2; /bin/cat "$1" || exit 3; printf '\n'; if [ "$2" = wait ]; then while [ ! -e "$3" ]; do /bin/sleep 0.01; done; fi; exit "$4""#
            child = try ClusterCalibrationProcess(launch: .init(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script, "private-report-fixture", file.path, wait ? "wait" : "exit", releaseFile.path,
                    change == "nonzero" ? "7" : "0"], environment: [:], initialInput: f.authorized.credentialInput),
                expectedIdentity: identity, rank: f.authorized.body.selection.rank, profile: profile,
                executionPlanSHA256: change == "plan" ? String(repeating: "f", count: 64) : bound.executionPlanSHA256,
                authorizationSHA256: digest, normalizedConfigurationSHA256: f.quotation.response.normalizedConfigurationSHA256,
                environmentSHA256: f.quotation.response.executionEnvironmentSHA256,
                initialLeaseDeadline: end, experimentDeadline: end, plannedBytes: UInt64(f.quotation.response.loadCapacityBytes))
        }
        func release() throws { try Data().write(to: releaseFile, options: .withoutOverwriting) }
        func wait(_ condition: () -> Bool) throws {
            let end = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
            while !condition() && DispatchTime.now().uptimeNanoseconds < end { usleep(1000) }
            try #require(condition())
        }
        func cleanup() {
            if !FileManager.default.fileExists(atPath: releaseFile.path) { try? release() }
            child.cancel()
            #expect(child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000),
                "Actual child must be joined before scratch removal")
            if child.observedExit { try? FileManager.default.removeItem(at: root) }
        }
    }
}
