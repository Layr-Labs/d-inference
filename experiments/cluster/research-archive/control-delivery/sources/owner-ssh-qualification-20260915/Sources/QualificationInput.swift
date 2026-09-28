import Foundation
import Darwin
import CryptoKit
import DarkbloomClusterProtocol

enum QualificationFailure: Error { case invalid(String) }
func readQualificationBytes(_ path: String, maximum: Int) throws -> (Data, String) {
    let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw QualificationFailure.invalid("Cannot open input") }
    defer { Darwin.close(fd) }
    var a = stat(), b = stat()
    guard fstat(fd, &a) == 0, a.st_mode & S_IFMT == S_IFREG, a.st_size > 0, a.st_size <= maximum else { throw QualificationFailure.invalid("Input is not a bounded regular file") }
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n < 0 && errno == EINTR { continue }
        guard n >= 0, data.count + max(n, 0) <= maximum else { throw QualificationFailure.invalid("Input changed or read failed") }
        if n == 0 { break }; data.append(contentsOf: buffer.prefix(n))
    }
    guard fstat(fd, &b) == 0, a.st_dev == b.st_dev, a.st_ino == b.st_ino, a.st_mode == b.st_mode,
          a.st_size == b.st_size, data.count == a.st_size,
          a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec, a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec,
          a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec, a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec else { throw QualificationFailure.invalid("Input changed") }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return (data, hash)
}
func readQualificationJSON(_ path: String, maximum: Int) throws -> (Data, String) {
    let (data, hash) = try readQualificationBytes(path, maximum: maximum)
    var framed = data; if framed.last != 10 { framed.append(10) }
    try validateClusterWorkerEnvelope(framed, commandStream: true)
    return (data, hash)
}
func qualificationTemplate(_ encoded: String) throws -> ClusterWorkerReady {
    guard let data = Data(base64Encoded: encoded), data.count <= ClusterWorkerLimits.eventBytes,
          case .ready(let ready) = try ClusterWorkerCodec.decodeEvent(data).event else { throw QualificationFailure.invalid("Invalid ready template") }
    return ready
}
func qualificationEmit(_ value: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    guard data.count <= 4 * 1024 * 1024 else { throw QualificationFailure.invalid("Controller record too large") }
    data.append(10); try FileHandle.standardOutput.write(contentsOf: data)
}
