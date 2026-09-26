import Foundation

extension DeviceCheckEvidence {
    static let maxLogBytes = 8 * 1024 * 1024
    static let maxLogLineBytes = 64 * 1024

    /// Read only the newest bounded bytes, discarding a possibly partial first line.
    static func readTail(_ url: URL, limit: Int, wholeLines: Bool) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: limit) ?? Data()
        if start > 0 && wholeLines {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return Data() }
            return Data(data[data.index(after: newline)...])
        }
        return data
    }

    /// Keeps only lines matching a closed pattern; oldest events are dropped
    /// past `maxEvents`.
    static func extract(ndjson: Data) -> [Event] {
        let expressions = Pattern.allCases.compactMap { pattern in pattern.expression.map { (pattern, $0) } }
        var events: [Event] = []
        events.reserveCapacity(maxEvents)
        var next = 0
        let data = ndjson.suffix(maxLogBytes)
        var start = data.startIndex
        if ndjson.count > maxLogBytes {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return [] }
            start = data.index(after: newline)
        }
        // Walk one line at a time; split() would allocate a slice for every line.
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let line = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : end
            guard !line.isEmpty, line.count <= maxLogLineBytes else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["eventMessage"] as? String else { continue }
            let range = NSRange(message.startIndex..., in: message)
            let matches: [Match] = expressions.compactMap { pattern, expression in
                guard let found = expression.firstMatch(in: message, range: range) else { return nil }
                var code: Int32?
                if found.numberOfRanges > 1, let group = Range(found.range(at: 1), in: message) {
                    code = Int(message[group]).flatMap { Int32(exactly: $0) }
                }
                return Match(pattern: pattern, code: code)
            }
            guard !matches.isEmpty else { continue }
            let event = Event(timestamp: closed(object["timestamp"], limit: 40) ?? "",
                                category: closed(object["category"], limit: 64),
                                messageType: closed(object["messageType"], limit: 16),
                                matches: matches)
            if events.count < maxEvents { events.append(event) }
            else { events[next] = event }
            next = (next + 1) % maxEvents
        }
        guard events.count == maxEvents else { return events }
        return Array(events[next...]) + Array(events[..<next])
    }

    /// Timestamp/category/type are Apple-defined tokens; keep only a bounded,
    /// conservative character set so no message text can ride along.
    private static func closed(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String, !text.isEmpty, text.count <= limit else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " .:-+_"))
        return text.unicodeScalars.allSatisfy(allowed.contains) ? text : nil
    }

}
