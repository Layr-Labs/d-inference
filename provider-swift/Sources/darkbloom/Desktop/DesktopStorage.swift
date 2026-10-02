import Crypto
import Darwin
import Foundation
import ProviderCore

enum DesktopStorage {
  static var directory: URL {
    if let path = ProcessInfo.processInfo.environment["DARKBLOOM_DESKTOP_DIR"] {
      return URL(fileURLWithPath: path)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".darkbloom/desktop")
  }

  static func prepare() throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory,
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
    else { throw CocoaError(.fileReadNoPermission) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  static func write<T: Encodable>(_ value: T, name: String) throws {
    try prepare()
    let data = try JSONEncoder().encode(value)
    let temporary = directory.appendingPathComponent(".\(UUID().uuidString)")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    guard rename(temporary.path, directory.appendingPathComponent(name).path) == 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  static func read<T: Decodable>(_ type: T.Type, name: String) -> T? {
    let url = directory.appendingPathComponent(name)
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      attrs[.type] as? FileAttributeType == .typeRegular,
      (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
      let data = try? Data(contentsOf: url), data.count <= 2_000_000
    else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  static func revision(_ path: URL) -> String {
    SHA256.hash(data: (try? Data(contentsOf: path)) ?? Data()).map { String(format: "%02x", $0) }
      .joined()
  }
}

struct DesktopDiscovery: Codable, Sendable {
  let version: Int
  let port: Int
  let token: String
  let pid: Int32
  let instance: String
}
