import Foundation
import Darwin
import DarkbloomClusterProcess

/// A bounded child for the wizard's own questions to tools and to the other
/// Mac over SSH: fixed arguments, optional input, both outputs kept up to a
/// bound, and a deadline after which it is ended. It is never used for a
/// rank: ranks are owned by the installed session.
enum ClusterSetupChild {
    struct Outcome: Sendable, Equatable {
        let status: Int32
        let output: Data
        let error: Data
        var errorText: String { String(decoding: error, as: UTF8.self) }
    }

    struct TimedOut: Error, CustomStringConvertible { var description: String { "it did not answer in time" } }

    static func run(executable: URL, arguments: [String], environment: [String: String]? = nil, input: Data? = nil,
                    seconds: Double, maximumOutputBytes: Int) throws -> Outcome {
        let child = Process(), output = Pipe(), error = Pipe(), stdin = Pipe()
        child.executableURL = executable; child.arguments = arguments
        child.environment = environment ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        child.standardInput = input == nil ? FileHandle.nullDevice : stdin
        child.standardOutput = output; child.standardError = error
        let handles = [output.fileHandleForReading, error.fileHandleForReading]
        for handle in handles {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        let exit = ClusterProcessExit()
        var launched = false
        defer {
            if launched {
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
                exit.wait()
            }
            for handle in handles { try? handle.close() }
            try? output.fileHandleForWriting.close(); try? error.fileHandleForWriting.close()
        }
        try exit.run(child); launched = true
        try output.fileHandleForWriting.close(); try error.fileHandleForWriting.close()
        if let input {
            // Small inputs only (a setup): written whole, then closed so the other end sees its end.
            let writer = stdin.fileHandleForWriting
            try? writer.write(contentsOf: input)
            try? writer.close()
        }
        let deadline = Date().addingTimeInterval(seconds)
        var data = [Data(), Data()], open = [true, true]
        let limits = [maximumOutputBytes, 16 * 1024]
        while open.contains(true) || child.isRunning {
            guard Date() < deadline else { throw TimedOut() }
            var descriptors = handles.enumerated().map { index, handle in
                pollfd(fd: open[index] ? handle.fileDescriptor : -1, events: Int16(POLLIN), revents: 0)
            }
            let status = descriptors.withUnsafeMutableBufferPointer { Darwin.poll($0.baseAddress, nfds_t($0.count), 50) }
            if status < 0 && errno == EINTR { continue }
            for index in 0..<2 where descriptors[index].revents != 0 {
                var buffer = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(handles[index].fileDescriptor, &buffer, buffer.count)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                if count <= 0 { open[index] = false; continue }
                // Beyond its bound an output is dropped, not an error: the status decides.
                if data[index].count < limits[index] { data[index].append(contentsOf: buffer.prefix(min(count, limits[index] - data[index].count))) }
            }
        }
        exit.wait()
        return .init(status: child.terminationStatus, output: data[0], error: data[1])
    }

    /// Why an SSH connection to the other Mac failed, in plain words, from
    /// OpenSSH's own message. The message itself is not shown: it can name
    /// the host and its address.
    static func sshFailure(_ outcome: Outcome) -> String {
        let text = outcome.errorText.lowercased()
        if text.contains("host key verification failed") || text.contains("remote host identification has changed") {
            return "the other Mac's host key is not the one the setup pins"
        }
        if text.contains("permission denied") {
            return "the other Mac refused this Mac (developer route)"
        }
        if text.contains("timed out") || text.contains("no route to host") || text.contains("host is down") {
            return "the other Mac did not answer (asleep, cable out, or another address)"
        }
        if text.contains("connection refused") { return "the other Mac refused the connection (developer route)" }
        if text.contains("could not resolve") { return "the other Mac's name did not resolve" }
        if outcome.status == 127 || text.contains("no such file") || text.contains("not found") {
            return "Darkbloom is not installed on the other Mac at the path the setup names"
        }
        if text.contains("unsafe configured ssh trust file") { return "this Mac's pinned trust files are not owner-only regular files" }
        return "the command there ended with status \(outcome.status)"
    }
}

/// Reads one server-sent event line of a streamed chat completion.
enum ClusterSetupStream {
    struct Chunk: Equatable, Sendable {
        var content: String?
        /// The delta carried reasoning (a thinking model's first tokens).
        var reasoning = false
        var finishReason: String?
        var completionTokens: Int?
        var done: Bool
        var error: String?
    }

    /// `data: {...}` with choices[0].delta.content, a finish reason, usage,
    /// an error object, or `data: [DONE]`. Anything else is nil.
    static func parse(_ line: String) -> Chunk? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .init(done: true) }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var chunk = Chunk(done: false)
        if let error = object["error"] as? [String: Any] {
            chunk.error = ClusterConsoleText.bounded((error["message"] as? String) ?? "the server sent an error", maximum: 200)
        }
        if let choice = (object["choices"] as? [[String: Any]])?.first {
            let delta = choice["delta"] as? [String: Any]
            chunk.content = delta?["content"] as? String
            chunk.reasoning = ["reasoning_content", "reasoning"].contains { (delta?[$0] as? String)?.isEmpty == false }
            chunk.finishReason = choice["finish_reason"] as? String
        }
        if let usage = object["usage"] as? [String: Any] { chunk.completionTokens = (usage["completion_tokens"] as? NSNumber)?.intValue }
        return chunk
    }
}

extension ClusterSetupLive {
    /// The leader's status report as the screen shows it.
    init(status: ClusterDiagnosticsReport, localWiredBytes: Int?, localPhysicalBytes: Int?, linkState: String?) {
        guard let live = status.live else {
            let reason = status.checks.first { $0.name == "localServingObservation" }?.detail
            self.init(observed: false, detail: reason ?? "no leader answered", localWiredBytes: localWiredBytes,
                localPhysicalBytes: localPhysicalBytes, linkState: linkState)
            return
        }
        self.init(observed: true, ready: live.ready, hostPhase: live.hostPhase, sessionPhase: live.session.phase,
            port: Int(live.boundPort), generationMode: live.session.observedGenerationMode?.rawValue,
            members: live.session.members.map { member in
                .init(rank: member.rank, memberID: member.peerID, ready: member.nativeReady, cleanupObserved: member.nativeCleanupObserved,
                    releaseAcknowledged: member.ownerReleaseAcknowledged,
                    termination: member.ownerTermination.map { $0.kind.rawValue + ($0.status.map { " \($0)" } ?? "") })
            },
            requestsServed: live.session.admission?.requestsServed,
            keepWarmExchanges: live.session.admission?.keepWarmExchanges,
            activeRequest: live.session.admission?.activeRequest ?? false, quarantined: live.quarantined,
            localWiredBytes: localWiredBytes, localPhysicalBytes: localPhysicalBytes, linkState: linkState)
    }
}

extension ClusterSetupReport {
    /// Free text from errors and checks, passed through the redaction the console uses.
    func cleaned(_ clean: ClusterConsoleFreeText) -> ClusterSetupReport {
        var copy = self
        copy.mac.profileError = clean(mac.profileError)
        copy.link.guidance = clean(link.guidance)
        copy.link.thunderboltError = clean(link.thunderboltError)
        if var port = copy.link.port { port.isolationGuidance = clean(port.isolationGuidance); copy.link.port = port }
        copy.saved.error = clean(saved.error)
        copy.saved.setup?.workerDetail = clean(saved.setup?.workerDetail)
        copy.inboxError = clean(inboxError)
        copy.modelsError = clean(modelsError)
        copy.memoryGuard.detail = clean(memoryGuard.detail)
        copy.checks = checks.map { .init(name: $0.name, outcome: $0.outcome, detail: clean($0.detail)) }
        return copy
    }
}
