import Darwin
import Foundation

extension FileHandle {
    /// What the pipe holds now, up to `count` bytes, as soon as any arrives; empty at end of file. On Darwin
    /// `read(upToCount:)` waits on a pipe until it has `count` bytes or reaches end of file, so a child's lines would
    /// arrive only in chunks of `count`, or when it exits: an approval link that a child prints and then waits on would
    /// never be read in time. Plain `read(2)` into a buffer of its own, so no autoreleased storage builds up either
    /// (`readDrained`).
    func readAvailable(upToCount count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        while true {
            let read = buffer.withUnsafeMutableBytes { Darwin.read(fileDescriptor, $0.baseAddress, count) }
            if read >= 0 { return Data(buffer[0..<read]) }
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
}
