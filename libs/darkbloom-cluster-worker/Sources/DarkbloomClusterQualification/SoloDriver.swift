import Darwin
import Foundation

/// One Mac alone, timed on this driver's clock exactly as a pair is: the
/// request travels first, the clock starts when the start command is written,
/// and each token is stamped when its event arrives here.
///
/// The Mac runs `darkbloom-cluster-reference --serve yes`: both stages of the
/// registered artifact in one process, no collective, no capture. It is reached
/// through a local shell or through `ssh`, like a pair's ranks. This driver
/// never signals it: on any failure the input is closed and the process ends
/// by itself, at the latest at the lifetime it was started with.
public struct SoloConfiguration: Sendable {
    public var request: QualificationRequest
    public var stageCut: Int
    public var modelDirectory: String
    public var servicePath: String
    /// `["/bin/sh", "-c"]` for this Mac, or the `ssh` argument vector.
    public var transport: [String]
    public var remote: Bool
    public var repetitions: Int
    public var lifetimeSeconds: Int
    public var startupSeconds: Int
    public var requestSeconds: Int
    public var role: String
    public var sensitive: [String]

    public init(request: QualificationRequest, stageCut: Int, modelDirectory: String, servicePath: String,
                transport: [String], remote: Bool, repetitions: Int = 1, lifetimeSeconds: Int = 240,
                startupSeconds: Int = 120, requestSeconds: Int = 100, role: String = "single host",
                sensitive: [String] = []) throws {
        self.request = request; self.stageCut = stageCut; self.modelDirectory = modelDirectory
        self.servicePath = servicePath; self.transport = transport; self.remote = remote
        self.repetitions = repetitions; self.lifetimeSeconds = lifetimeSeconds
        self.startupSeconds = startupSeconds; self.requestSeconds = requestSeconds
        self.role = role; self.sensitive = sensitive
        try request.validate()
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw QualificationError("Solo configuration: " + message) }
        }
        try require(request.supportedCuts.contains(stageCut), "stage cut must be one of the request model's cuts: "
            + request.supportedCuts.map(String.init).joined(separator: ", "))
        try require(PairConfiguration.isPath(modelDirectory), "model directory must be a plain absolute path")
        try require(PairConfiguration.isPath(servicePath), "service must be a plain absolute path")
        try require((1...PairConfiguration.maximumRepetitions).contains(repetitions), "repetitions must be 1...8")
        try require((10...300).contains(lifetimeSeconds), "lifetime must be 10...300 seconds")
        try require((2...lifetimeSeconds).contains(startupSeconds), "startup timeout must be 2 seconds up to the lifetime")
        try require((5...lifetimeSeconds).contains(requestSeconds), "request timeout must be 5 seconds up to the lifetime")
        try require(!transport.isEmpty && transport[0].hasPrefix("/")
            && transport.allSatisfy { !$0.isEmpty && !$0.utf8.contains(0) && $0.utf8.count <= 2048 },
            "transport must be an absolute executable and its arguments")
        try require(!role.isEmpty && role.utf8.count <= 64, "role must be a short label")
    }

    func command(_ script: String) -> [String] {
        transport + [remote ? "/bin/sh -c " + PairConfiguration.quoted(script) : script]
    }

    /// Hashes, hardware, service processes from this path and wired memory.
    var inspectionScript: String {
        """
        set -eu
        W=\(PairConfiguration.quoted(servicePath))
        D=$(/usr/bin/dirname "$W")
        printf 'service=%s\\n' "$(/usr/bin/shasum -a 256 "$W" | /usr/bin/cut -d ' ' -f 1)"
        printf 'metallib=%s\\n' "$(/usr/bin/shasum -a 256 "$D/mlx.metallib" | /usr/bin/cut -d ' ' -f 1)"
        printf 'chip=%s\\n' "$(/usr/sbin/sysctl -n machdep.cpu.brand_string)"
        printf 'os=%s\\n' "$(/usr/bin/sw_vers -productVersion)"
        \(Self.runningScript)
        """
    }
    var runningScript: String { "set -eu\nW=\(PairConfiguration.quoted(servicePath))\n\(Self.runningScript)" }
    private static let runningScript = """
        printf 'running=%s\\n' "$(/bin/ps -axo comm= | /usr/bin/awk -v w="$W" '$0 == w { n++ } END { print n + 0 }')"
        printf 'wired=%s\\n' "$(/usr/bin/vm_stat | /usr/bin/awk -v p="$(/usr/sbin/sysctl -n hw.pagesize)" '/Pages wired down/ { gsub("[.]", "", $4); printf "%.0f", $4 * p }')"
        """

    /// The service with an exact environment of its own. Interrupt and hangup
    /// are ignored, so an interrupted driver does not take a loaded model down.
    var launchScript: String {
        let environment = ([("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"), ("LANG", "C"), ("LC_ALL", "C")]
            + request.arithmeticEnvironment).map { "\($0.0)=\(PairConfiguration.quoted($0.1))" }.joined(separator: " ")
        let arguments = ["--model-dir", modelDirectory, "--stage-cut", String(stageCut), "--serve", "yes",
                         "--deadline-seconds", String(lifetimeSeconds)].map(PairConfiguration.quoted).joined(separator: " ")
        return """
        set -eu
        trap '' INT HUP
        exec /usr/bin/env -i \(environment) \(PairConfiguration.quoted(servicePath)) \(arguments)
        """
    }
}

/// One request of a solo run. The first group is on the driver's clock; the
/// second is what the service measured on its own clock, for comparison.
public struct SoloRepetitionTiming: Codable, Equatable, Sendable {
    public var requestID: String
    public var firstTokenSeconds: Double
    public var prefillTokensPerSecond: Double
    public var decodeSeconds: Double
    public var decodeTokensPerSecond: Double?
    public var totalSeconds: Double
    public var tokens: Int
    public var selectedTokenIDsSHA256: String
    public var finishReason: String

    public var serviceFirstTokenSeconds: Double?
    public var serviceLastTokenSeconds: Double?
    public var serviceRetiredSeconds: Double?
    public var residualCopies: Int?
    public var activeBytesDuringRequest: Int?
    public var activeBytesAfterRetirement: Int?
}

public struct SoloReport: Codable, Equatable, Sendable {
    public static let currentSchema = "darkbloom_cluster_solo_report_v1"
    public var schema = SoloReport.currentSchema
    public var kind = "singleHostService"
    public var createdUTC = QualificationReportFiles.timestamp()
    /// `completed` or `failed`.
    public var outcome: String
    public var failure: String?
    public var role: String
    public var remote: Bool
    public var chip: String?
    public var operatingSystem: String?
    public var serviceSHA256: String?
    public var metallibSHA256: String?
    public var stageCut: Int
    public var promptTokenCount: Int
    public var promptTokenIDsSHA256: String
    public var chunkSize: Int
    public var outputCount: Int
    public var readySeconds: Double?
    public var stageLoadSeconds: [Double]?
    public var activeBytesBefore: Int?
    public var activeBytesLoaded: Int?
    public var repetitions: [SoloRepetitionTiming] = []
    public var repetitionsAgreeOnTokens: Bool?
    public var selectedTokenIDs: [Int]?
    public var stageModelsReleased: Bool?
    public var activeBytesAfterRelease: Int?
    public var cacheBytesAfterRelease: Int?
    public var peakBytes: Int?
    public var exitStatus: Int32?
    public var exitSignal: Int32?
    public var signalsSentByDriver = 0
    public var serviceProcessesLeft: Int?
    public var wiredBytesBefore: Int?
    public var wiredBytesAfter: Int?
    public var diagnostics: String?
    public var note = "Driver clock: from writing the start command to the arrival of each token event and of the "
        + "finished event. The request itself is sent and acknowledged before the start command."
}

public struct SoloDriver: Sendable {
    public let configuration: SoloConfiguration
    public var log: @Sendable (String) -> Void = { _ in }

    public init(configuration: SoloConfiguration) { self.configuration = configuration }

    /// Events of the service, each stamped on arrival.
    private final class Stream: @unchecked Sendable {
        private let lock = NSLock()
        private let arrivals = DispatchSemaphore(value: 0)
        private var events: [(object: [String: Any], at: UInt64)] = []
        private var ended = false
        private var errors = Data()

        func append(line: Data, at stamp: UInt64) {
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            lock.lock(); events.append((object ?? ["event": "unreadable"], stamp)); lock.unlock()
            arrivals.signal()
        }
        func end() { lock.lock(); ended = true; lock.unlock(); arrivals.signal() }
        func appendDiagnostics(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            errors.append(chunk)
            if errors.count > 16_384 { errors.removeFirst(errors.count - 16_384) }
        }
        var diagnostics: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errors, as: UTF8.self) }

        /// The next event, or nil when the stream ended or the deadline passed.
        func next(until deadline: UInt64) -> (object: [String: Any], at: UInt64)? {
            while true {
                lock.lock()
                if !events.isEmpty { let value = events.removeFirst(); lock.unlock(); return value }
                let over = ended
                lock.unlock()
                let now = DispatchTime.now().uptimeNanoseconds
                if over || now >= deadline { return nil }
                _ = arrivals.wait(timeout: .init(uptimeNanoseconds: min(deadline, now + 50_000_000)))
            }
        }
    }

    public func run() -> SoloReport {
        let c = configuration
        let redact = PairRedactor(sensitive: c.sensitive)
        var report = SoloReport(outcome: "failed", role: c.role, remote: c.remote, stageCut: c.stageCut,
            promptTokenCount: c.request.promptTokenIDs.count, promptTokenIDsSHA256: c.request.promptTokenIDsSHA256,
            chunkSize: c.request.chunkSize, outputCount: c.request.outputCount)
        func fail(_ message: String) -> SoloReport {
            report.outcome = "failed"; report.failure = redact(message)
            log("solo: failed: \(redact(message))")
            return report
        }
        // 1. The Mac, before anything is launched.
        do {
            let fields = PairDriver.fields(try helper(c.inspectionScript, seconds: 60))
            guard let service = fields["service"], QualificationHash.isSHA256(service),
                  let metallib = fields["metallib"], QualificationHash.isSHA256(metallib),
                  let running = fields["running"].flatMap({ Int($0) }) else {
                return fail("the service or the mlx.metallib beside it could not be hashed")
            }
            report.serviceSHA256 = service; report.metallibSHA256 = metallib
            report.chip = fields["chip"]; report.operatingSystem = fields["os"]
            report.wiredBytesBefore = fields["wired"].flatMap { Int($0) }
            guard running == 0 else { return fail("\(running) service process(es) from this path are already running") }
        } catch { return fail("inspection failed: \(error)") }

        // 2. Launch and wait for both stages.
        let command = c.command(c.launchScript)
        let process = Process(), input = Pipe(), output = Pipe(), diagnostics = Pipe()
        process.executableURL = URL(fileURLWithPath: command[0]); process.arguments = Array(command.dropFirst())
        process.environment = PairConfiguration.transportEnvironment
        process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            return fail("cannot suppress pipe SIGPIPE")
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let stream = Stream()
        let launched = DispatchTime.now().uptimeNanoseconds
        do { try process.run() } catch { return fail("launch failed: \(error)") }
        try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        try? diagnostics.fileHandleForWriting.close()
        let outputDescriptor = output.fileHandleForReading.fileDescriptor
        let diagnosticDescriptor = diagnostics.fileHandleForReading.fileDescriptor
        Thread.detachNewThread {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(outputDescriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let stamp = DispatchTime.now().uptimeNanoseconds
                pending.append(contentsOf: buffer.prefix(count))
                while let newline = pending.firstIndex(of: 10) {
                    stream.append(line: Data(pending[pending.startIndex..<newline]), at: stamp)
                    pending.removeSubrange(pending.startIndex...newline)
                }
                if pending.count > 1 << 20 { break }
            }
            stream.end()
        }
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(diagnosticDescriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                stream.appendDiagnostics(Data(buffer.prefix(count)))
            }
        }
        var inputOpen = true
        func closeInput() { if inputOpen { inputOpen = false; try? input.fileHandleForWriting.close() } }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        /// Withdraws the service by ending its input, waits for it to end by
        /// itself and fills in what the Mac looks like afterwards.
        func conclude(_ outcome: String, _ failure: String?) -> SoloReport {
            closeInput()
            let limit = DispatchTime.now().uptimeNanoseconds + UInt64(c.lifetimeSeconds + 20) * 1_000_000_000
            if exited.wait(timeout: .init(uptimeNanoseconds: limit)) == .success {
                if process.terminationReason == .uncaughtSignal { report.exitSignal = process.terminationStatus }
                else { report.exitStatus = process.terminationStatus }
            }
            let fields = (try? helper(c.runningScript, seconds: 30)).map { PairDriver.fields($0) } ?? [:]
            report.serviceProcessesLeft = fields["running"].flatMap { Int($0) }
            report.wiredBytesAfter = fields["wired"].flatMap { Int($0) }
            let tail = redact(stream.diagnostics).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { report.diagnostics = String(tail.suffix(2000)) }
            report.outcome = outcome; report.failure = failure.map { redact($0) }
            if let failure { log("solo: \(outcome): \(redact(failure))") }
            return report
        }
        func integer(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

        guard let ready = stream.next(until: launched + UInt64(c.startupSeconds) * 1_000_000_000),
              ready.object["event"] as? String == "ready" else {
            return conclude("failed", "the service did not report ready within \(c.startupSeconds) s")
        }
        report.readySeconds = Double(ready.at - launched) / 1e9
        report.stageLoadSeconds = (ready.object["stageLoadSeconds"] as? [NSNumber])?.map(\.doubleValue)
        report.activeBytesBefore = integer(ready.object["activeBytesBefore"])
        report.activeBytesLoaded = integer(ready.object["activeBytesLoaded"])
        log("solo: ready after \(String(format: "%.1f", report.readySeconds!)) s")

        // 3. The requests, one after another in the same loaded process.
        var firstTokens: [Int] = []
        for repetition in 0..<c.repetitions {
            let requestID = (repetition == 0 ? c.request.requestUUID : UUID()).uuidString.lowercased()
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(c.requestSeconds) * 1_000_000_000
            do {
                try send(["command": "prepare", "requestID": requestID, "promptTokenIDs": c.request.promptTokenIDs,
                          "stopTokenIDs": c.request.stopTokenIDs, "chunkSize": c.request.chunkSize,
                          "outputCount": c.request.outputCount])
            } catch { return conclude("failed", "the request could not be sent: \(error)") }
            guard let prepared = stream.next(until: deadline), prepared.object["event"] as? String == "prepared",
                  prepared.object["requestID"] as? String == requestID else {
                return conclude("failed", "the service did not acknowledge request \(repetition + 1)")
            }
            let started = DispatchTime.now().uptimeNanoseconds
            do { try send(["command": "start", "requestID": requestID]) }
            catch { return conclude("failed", "the start command could not be sent: \(error)") }
            var tokens: [Int] = [], stamps: [UInt64] = []
            var finished: (object: [String: Any], at: UInt64)?
            while finished == nil {
                guard let event = stream.next(until: deadline) else {
                    return conclude("failed", "request \(repetition + 1) did not finish before its deadline after \(tokens.count) token(s)")
                }
                switch event.object["event"] as? String {
                case "token":
                    guard integer(event.object["ordinal"]) == tokens.count, let token = integer(event.object["tokenID"]) else {
                        return conclude("failed", "the service reported a token out of order")
                    }
                    tokens.append(token); stamps.append(event.at)
                case "finished": finished = event
                default: return conclude("failed", "the service reported an unexpected event during request \(repetition + 1)")
                }
            }
            guard let finished, let first = stamps.first, let last = stamps.last,
                  integer(finished.object["tokens"]) == tokens.count, let reason = finished.object["reason"] as? String else {
                return conclude("failed", "request \(repetition + 1) finished without tokens")
            }
            func seconds(_ name: String) -> Double? { (finished.object[name] as? NSNumber).map { $0.doubleValue / 1e9 } }
            let firstToken = Double(first - started) / 1e9, decode = Double(last - first) / 1e9
            report.repetitions.append(.init(requestID: requestID, firstTokenSeconds: firstToken,
                prefillTokensPerSecond: Double(c.request.promptTokenIDs.count) / firstToken, decodeSeconds: decode,
                decodeTokensPerSecond: tokens.count > 1 && last > first ? Double(tokens.count - 1) / decode : nil,
                totalSeconds: Double(finished.at - started) / 1e9, tokens: tokens.count,
                selectedTokenIDsSHA256: QualificationHash.tokenIDs(tokens), finishReason: reason,
                serviceFirstTokenSeconds: seconds("firstTokenNanoseconds"),
                serviceLastTokenSeconds: seconds("lastTokenNanoseconds"),
                serviceRetiredSeconds: seconds("retiredNanoseconds"),
                residualCopies: integer(finished.object["residualCopies"]),
                activeBytesDuringRequest: integer(finished.object["activeBytesDuringRequest"]),
                activeBytesAfterRetirement: integer(finished.object["activeBytesAfterRetirement"])))
            if repetition == 0 { firstTokens = tokens; report.selectedTokenIDs = tokens }
            if c.repetitions > 1 { report.repetitionsAgreeOnTokens = (report.repetitionsAgreeOnTokens ?? true) && tokens == firstTokens }
            log("solo: request \(repetition + 1) of \(c.repetitions) finished (\(reason)) with \(tokens.count) tokens, "
                + "first token after \(String(format: "%.3f", firstToken)) s")
        }

        // 4. Release and exit.
        do { try send(["command": "shutdown"]) } catch { return conclude("failed", "shutdown could not be sent: \(error)") }
        guard let released = stream.next(until: DispatchTime.now().uptimeNanoseconds + 60_000_000_000),
              released.object["event"] as? String == "released" else {
            return conclude("failed", "the service did not report its release")
        }
        report.stageModelsReleased = (released.object["stageModelsReleased"] as? NSNumber)?.boolValue
        report.activeBytesAfterRelease = integer(released.object["activeBytesAfterRelease"])
        report.cacheBytesAfterRelease = integer(released.object["cacheBytesAfterRelease"])
        report.peakBytes = integer(released.object["peakBytes"])
        let final = conclude("completed", nil)
        guard final.exitStatus == 0, final.stageModelsReleased == true, final.serviceProcessesLeft == 0 else {
            var failed = final
            failed.outcome = "failed"
            failed.failure = "the requests completed but the service did not release, exit with status 0 and leave no process"
            return failed
        }
        return final
    }

    /// A short command on that Mac: hashing and process listing. Never the
    /// loaded service. It is the only kind of process this driver may terminate.
    func helper(_ script: String, seconds: Int) throws -> Data {
        let command = configuration.command(script)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: command[0]); process.arguments = Array(command.dropFirst())
        process.environment = PairConfiguration.transportEnvironment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        try? output.fileHandleForWriting.close()
        let box = HelperOutput()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let reading = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 1 << 14)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                box.append(Data(buffer.prefix(count)))
            }
            reading.signal()
        }
        if finished.wait(timeout: .now() + .seconds(seconds)) != .success {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
            throw QualificationError("an inspection command did not finish within \(seconds) s")
        }
        _ = reading.wait(timeout: .now() + 5)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw QualificationError("an inspection command ended with status \(process.terminationStatus)")
        }
        return box.value
    }

    private final class HelperOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); if data.count < 1 << 20 { data.append(chunk) }; lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }
}
