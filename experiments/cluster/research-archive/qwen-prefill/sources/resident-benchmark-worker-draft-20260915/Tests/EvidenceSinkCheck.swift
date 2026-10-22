import Darwin
import Foundation

enum CheckFailure: Error { case failed(String) }
func require(_ condition: Bool, _ label: String) throws { if !condition { throw CheckFailure.failed(label) } }
func rejects(_ label: String, _ body: () throws -> Void) throws {
    var failed = false
    do { try body() } catch { failed = true }
    try require(failed, label)
}

@main enum EvidenceSinkCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cluster-evidence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = try ResidentEvidenceSink(path: root.path)
        let id = UUID(), bytes = Data(repeating: 0x61, count: 150_001)
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        try sink.publish(bytes, requestID: id, deadline: deadline)
        let file = root.appendingPathComponent(id.uuidString.lowercased() + ".json")
        try require(try Data(contentsOf: file) == bytes, "Complete bounded write")
        var info = stat(); try require(lstat(file.path, &info) == 0 && info.st_mode & 0o077 == 0, "Private file permissions")
        try rejects("Same request overwritten") { try sink.publish(Data([1]), requestID: id, deadline: deadline) }
        let anotherSink = try ResidentEvidenceSink(path: root.path)
        try rejects("Existing record overwritten by new sink") { try anotherSink.publish(Data([2]), requestID: id, deadline: deadline) }
        try require(try Data(contentsOf: file) == bytes, "Failed duplicate preserved bytes")
        let expired = UUID()
        try rejects("Expired request admitted") { try sink.publish(Data([1]), requestID: expired, deadline: 1) }
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(expired.uuidString.lowercased() + ".json").path), "Expired request created file")
        try rejects("Empty record admitted") { try sink.publish(Data(), requestID: UUID(), deadline: deadline) }
        try rejects("Oversize record admitted") { try sink.publish(Data(count: ResidentEvidenceSink.maximumBytes + 1), requestID: UUID(), deadline: deadline) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        try rejects("Linked directory admitted") { _ = try ResidentEvidenceSink(path: link.path) }
        let linkedID = UUID(), recordLink = root.appendingPathComponent(linkedID.uuidString.lowercased() + ".json")
        try FileManager.default.createSymbolicLink(at: recordLink, withDestinationURL: file)
        try rejects("Linked record overwritten") { try sink.publish(Data([1]), requestID: linkedID, deadline: deadline) }
        let publicDirectory = root.appendingPathComponent("public")
        try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try rejects("Nonprivate directory admitted") { _ = try ResidentEvidenceSink(path: publicDirectory.path) }
        print("{\"passed\":true,\"groups\":8,\"actualFileIO\":true,\"nativeModelExecution\":false}")
    }
}
