import Foundation
import ProviderCore

/// Repeats the read-only link inspection every few seconds and hands over what
/// changed, until told to stop or until SIGINT or SIGTERM. Shared by
/// `cluster link --watch` and by the wait for a cable in `cluster setup`.
enum ClusterLinkWatchLoop {
    /// Ctrl-C also reaches the tools of a reading in flight, and a reading cut
    /// short looks like a change. An interrupt gets this long to be noticed
    /// before a change is believed.
    private static let interruptGraceMilliseconds = 200

    /// `cluster link --watch`: one line, or one JSON object, per change.
    static func printChanges(json: Bool) async throws {
        _ = try await poll(after: nil) { events in
            for event in events { emit(event, json: json) }
            return true
        }
    }

    /// The first reading that differs from `previous`; nil when interrupted.
    static func nextChange(after previous: ClusterLinkReadinessReport?) async throws -> ClusterLinkReadinessReport? {
        try await poll(after: previous) { _ in false }
    }

    /// Polls until `keepWatching` returns false, and returns the reading that
    /// ended it; nil when a signal ended it instead. The signal handling is
    /// installed only for the duration, so Ctrl-C behaves normally afterwards.
    private static func poll(
        after initial: ClusterLinkReadinessReport?,
        keepWatching: @escaping @Sendable ([ClusterLinkWatchEvent]) -> Bool
    ) async throws -> ClusterLinkReadinessReport? {
        let signals = try DistributedStartSignals()
        defer { signals.close() }
        let polling = Task { () -> ClusterLinkReadinessReport? in
            var previous = initial
            while !Task.isCancelled {
                // Ports and states only: the network settings are not read every poll.
                let report = await Task.detached { ClusterLinkReadinessProbe.inspectLocalLink(isolation: false) }.value
                let events = ClusterLinkWatch.events(previous: previous, current: report)
                if !events.isEmpty {
                    try? await Task.sleep(for: .milliseconds(interruptGraceMilliseconds))
                    guard !Task.isCancelled else { break }
                    if !keepWatching(events) { return report }
                }
                previous = report
                try? await Task.sleep(for: .seconds(ClusterLinkWatch.pollIntervalSeconds))
            }
            return nil
        }
        signals.attach { polling.cancel() }
        return await polling.value
    }

    private static func emit(_ event: ClusterLinkWatchEvent, json: Bool) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let line = try? encoder.encode(event) { print(String(decoding: line, as: UTF8.self)) }
        } else {
            for line in event.lines { print(line) }
        }
        // A reader on a pipe must see each change when it happens.
        fflush(stdout)
    }
}
