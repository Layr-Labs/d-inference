import Foundation

public struct ProbeError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
