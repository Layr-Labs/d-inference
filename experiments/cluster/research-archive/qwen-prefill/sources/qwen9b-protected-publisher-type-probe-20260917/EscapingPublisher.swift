import Foundation

enum Writer {
    static func publish(_ body: (Data) throws -> Void) rethrows {
        try body(Data([7]))
    }
}
enum Export {
    static func publish(to publisher: @escaping (Data, () throws -> Void) throws -> Void,
                        check: () throws -> Void) throws {
        try autoreleasepool {
            try Writer.publish { bytes in
                try publisher(bytes) { try check() }
                try check()
            }
        }
        try check()
    }
}
final class Owner {
    func startRecording(publishEvidence: @escaping (Data, () throws -> Void) throws -> Void) throws {
        try execute {
            func check() throws { try self.checkLive() }
            try Export.publish(to: publishEvidence, check: check)
        }
    }
    private func execute(_ prepare: () throws -> Void) rethrows { try prepare() }
    private func checkLive() throws {}
}
final class Sink {
    func publish(_ bytes: Data, resourceCheck: () throws -> Void) throws { try resourceCheck() }
}
func worker(owner: Owner, sink: Sink) throws {
    try owner.startRecording { bytes, liveCheck in
        try sink.publish(bytes, resourceCheck: liveCheck)
    }
}
