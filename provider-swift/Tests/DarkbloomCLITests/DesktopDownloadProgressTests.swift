import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

/// The desktop app runs `darkbloom models download` with its output in a pipe
/// and shows the last percent in that output as the operation's progress
/// (`DesktopBackend.downloadProgress`). The download's plain lines carry it.
struct DesktopDownloadProgressTests {
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var seconds: TimeInterval = 0

        func append(_ chunk: String) { lock.withLock { text += chunk } }
        var value: String { lock.withLock { text } }
        var now: TimeInterval { lock.withLock { seconds } }
        func advance(_ interval: TimeInterval) { lock.withLock { seconds += interval } }
    }

    @Test func desktopReadsTheProgressOfAPipedDownload() {
        let output = Output()
        let renderer = DownloadProgressRenderer(
            modelID: "mlx-community/gpt-oss-20b-MXFP4-Q8", totalBytes: 12_000_000_000, startBytes: 0,
            terminal: DownloadProgressTerminal(isTerminal: false, columns: { 80 }, clock: { output.now },
                                               output: { output.append($0) }))
        renderer.update(done: 0)
        #expect(DesktopBackend.downloadProgress(output.value) == 0)
        output.advance(31)
        renderer.update(done: 3_000_000_000)
        #expect(DesktopBackend.downloadProgress(output.value) == 0.25)
        output.advance(31)
        renderer.update(done: 9_000_000_000)
        #expect(DesktopBackend.downloadProgress(output.value) == 0.75)
        renderer.verifying()
        renderer.finish()
        #expect(DesktopBackend.downloadProgress(output.value) == 1)
    }
}
