// A stand-in for swift-log's `Logging` module, for the model-free check
// runners that compile provider sources with plain swiftc (no package
// dependencies). It accepts the calls those sources make and discards them;
// the provider itself links the real swift-log.
public struct Logger: Sendable {
    public enum MetadataValue: Sendable {
        case string(String)
        case stringConvertible(any CustomStringConvertible & Sendable)
        case array([MetadataValue])
        case dictionary([String: MetadataValue])
    }
    public typealias Metadata = [String: MetadataValue]
    public struct Message: ExpressibleByStringInterpolation, Sendable {
        public let text: String
        public init(stringLiteral value: String) { text = value }
        public init(stringInterpolation: DefaultStringInterpolation) { text = String(stringInterpolation: stringInterpolation) }
    }
    public enum Level: String, Sendable { case trace, debug, info, notice, warning, error, critical }
    public let label: String
    public var logLevel: Level = .info
    public init(label: String) { self.label = label }
    public func log(level: Level, _ message: @autoclosure () -> Message, metadata: @autoclosure () -> Metadata? = nil) {}
    public func trace(_ message: @autoclosure () -> Message, metadata: @autoclosure () -> Metadata? = nil) {}
    public func debug(_ message: @autoclosure () -> Message, metadata: @autoclosure () -> Metadata? = nil) {}
    public func info(_ message: @autoclosure () -> Message, metadata: @autoclosure () -> Metadata? = nil) {}
    public func notice(_ message: @autoclosure () -> Message, metadata: @autoclosure () -> Metadata? = nil) {}
    public func warning(_ message: @autoclosure () -> Message, metadata: @autoclosure () -> Metadata? = nil) {}
    public func error(_ message: @autoclosure () -> Message, metadata: @autoclosure () -> Metadata? = nil) {}
    public func critical(_ message: @autoclosure () -> Message, metadata: @autoclosure () -> Metadata? = nil) {}
}
