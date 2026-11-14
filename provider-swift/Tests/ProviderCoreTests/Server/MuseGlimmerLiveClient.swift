// Copyright © 2026 Eigen Labs.

import Darwin
import Foundation
import MLX

/// Loopback client and receipts for `MuseGlimmerLiveTests`. Every request and
/// measurement is one JSON line in the receipts file, so a run's numbers can
/// be read back without the console.
struct MuseGlimmerLiveClient {
    let port: UInt16
    let token: String
    let session: URLSession
    let receipt: URL?

    /// One streamed response, timed at the client. `firstTokenSeconds` is the
    /// first delta that carries reasoning, content or a call; `lastTokenSeconds`
    /// the last such delta.
    struct Streamed {
        var status = 0
        var body = ""
        var firstTokenSeconds: Double?
        var lastTokenSeconds: Double?
        var totalSeconds = 0.0
        var deltas = 0
        var content = ""
        var reasoning = ""
        var finish: String?
        var usage: [String: Any] = [:]
        var calls: [Int: (name: String, arguments: String)] = [:]
        var sawDone = false

        var promptTokens: Int { usage["prompt_tokens"] as? Int ?? 0 }
        var completionTokens: Int { usage["completion_tokens"] as? Int ?? 0 }
        var cachedTokens: Int {
            (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        }

        /// Tokens after the first over the time between the first and the
        /// last delta: decode speed as a streaming client sees it.
        var decodeTokensPerSecond: Double? {
            guard let first = firstTokenSeconds, let last = lastTokenSeconds, last > first,
                completionTokens > 1 else { return nil }
            return Double(completionTokens - 1) / (last - first)
        }
    }

    /// A receipts file by case name; a later line of the same name wins.
    static func receipts(_ url: URL) throws -> [String: [String: Any]] {
        var cases: [String: [String: Any]] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let name = object["case"] as? String else { continue }
            cases[name] = object
        }
        return cases
    }

    func record(_ fields: [String: Any]) throws {
        guard let receipt else { return }
        let line = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let handle = try FileHandle(forWritingTo: receipt)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line + Data([10]))
    }

    private func request(path: String, body: [String: Any]?) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }

    func post(_ body: [String: Any], path: String = "/v1/chat/completions", name: String) async throws
        -> (Int, Data)
    {
        let started = ContinuousClock.now
        let (data, response) = try await session.data(for: request(path: path, body: body))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try record(["case": name, "status": status, "seconds": Self.seconds(since: started),
                    "body": String(decoding: data, as: UTF8.self)])
        return (status, data)
    }

    func get(_ path: String) async throws -> (Int, String) {
        let (data, response) = try await session.data(for: request(path: path, body: nil))
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    /// Streams `body` and times its deltas. `onFirstToken` runs once, when the
    /// first token-bearing delta arrives (prefill has ended).
    func stream(_ body: [String: Any], name: String, onFirstToken: () -> Void = {}) async throws
        -> Streamed
    {
        var body = body
        body["stream"] = true
        body["stream_options"] = ["include_usage": true]
        var result = Streamed()
        let started = ContinuousClock.now
        let (bytes, response) = try await session.bytes(for: request(path: "/v1/chat/completions", body: body))
        result.status = (response as? HTTPURLResponse)?.statusCode ?? 0
        for try await line in bytes.lines {
            result.body += line + "\n"
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6)
            if payload == "[DONE]" { result.sawDone = true; continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            else { continue }
            if let usage = object["usage"] as? [String: Any] { result.usage = usage }
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { continue }
            if let finish = choice["finish_reason"] as? String { result.finish = finish }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            let content = delta["content"] as? String ?? ""
            let reasoning = delta["reasoning_content"] as? String ?? ""
            let calls = delta["tool_calls"] as? [[String: Any]] ?? []
            guard !content.isEmpty || !reasoning.isEmpty || !calls.isEmpty else { continue }
            let now = Self.seconds(since: started)
            if result.firstTokenSeconds == nil {
                result.firstTokenSeconds = now
                onFirstToken()
            }
            result.lastTokenSeconds = now
            result.deltas += 1
            result.content += content
            result.reasoning += reasoning
            for call in calls {
                let index = call["index"] as? Int ?? 0
                let function = call["function"] as? [String: Any] ?? [:]
                var entry = result.calls[index] ?? ("", "")
                entry.name += function["name"] as? String ?? ""
                entry.arguments += function["arguments"] as? String ?? ""
                result.calls[index] = entry
            }
        }
        result.totalSeconds = Self.seconds(since: started)
        try record(["case": name, "status": result.status, "seconds": result.totalSeconds,
                    "first_token_seconds": result.firstTokenSeconds ?? -1,
                    "last_token_seconds": result.lastTokenSeconds ?? -1, "deltas": result.deltas,
                    "prompt_tokens": result.promptTokens, "completion_tokens": result.completionTokens,
                    "cached_tokens": result.cachedTokens, "finish": result.finish ?? "none",
                    "decode_tok_s": result.decodeTokensPerSecond ?? -1,
                    "content": result.content, "reasoning": result.reasoning,
                    "calls": result.calls.sorted { $0.key < $1.key }.map { ["name": $0.value.name,
                        "arguments": $0.value.arguments] }])
        return result
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Process and MLX memory now. MLX's peak is since its last reset.
    static func memory(_ phase: String) -> [String: Any] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let ok = status == KERN_SUCCESS
        return ["case": "memory", "phase": phase,
                "phys_footprint_bytes": ok ? Int(info.phys_footprint) : -1,
                "resident_bytes": ok ? Int(info.resident_size) : -1,
                "mlx_active_bytes": Memory.activeMemory, "mlx_peak_bytes": Memory.peakMemory,
                "mlx_cache_bytes": Memory.cacheMemory]
    }

    static func resetPeakMemory() { Memory.peakMemory = 0 }

    static func loadAverage() -> [Double] {
        var values = [Double](repeating: -1, count: 3)
        _ = getloadavg(&values, 3)
        return values
    }
}
