import Foundation

/// Stands in for a binary that replaced an installed executable after it was
/// verified: it keeps the first line it reads from its input in
/// `recorded-stdin` beside itself, whatever arguments it was given.
@main enum InstalledStdinRecorder {
    static func main() throws {
        guard let line = readLine(strippingNewline: false) else { return }
        let file = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("recorded-stdin")
        try Data(line.utf8).write(to: file)
    }
}
