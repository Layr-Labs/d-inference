import Darwin
import Dispatch
import Foundation

struct BoundedProcessOutputSnapshot {
    let data: Data
    let truncated: Bool
}

final class BoundedProcessOutput: @unchecked Sendable {
    let writer: FileHandle

    private let maximumBytes: Int
    private let readDescriptor: Int32
    private let queue: DispatchQueue
    private let completion = DispatchGroup()
    private var source: DispatchSourceRead?
    private var data = Data()
    private var truncated = false
    private var finished = false

    init(maximumBytes: Int) throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw SandboxRuntimeError.unsupported(
                "failed to create process output pipe"
            )
        }

        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        do {
            try Self.configure(descriptor: readDescriptor, nonBlocking: true)
            try Self.configure(descriptor: writeDescriptor, nonBlocking: false)
        } catch {
            close(readDescriptor)
            close(writeDescriptor)
            throw error
        }

        self.maximumBytes = maximumBytes
        self.readDescriptor = readDescriptor
        self.writer = FileHandle(
            fileDescriptor: writeDescriptor,
            closeOnDealloc: true
        )
        self.queue = DispatchQueue(
            label: "io.darkbloom.sandbox.process-output.\(UUID().uuidString)"
        )

        let source = DispatchSource.makeReadSource(
            fileDescriptor: readDescriptor,
            queue: queue
        )
        self.source = source
        completion.enter()
        source.setEventHandler { [weak self] in
            self?.drainAvailableBytes()
        }
        source.setCancelHandler { [completion, readDescriptor] in
            close(readDescriptor)
            completion.leave()
        }
        source.resume()
    }

    func closeParentWriter() {
        try? writer.close()
    }

    func finish() -> BoundedProcessOutputSnapshot {
        closeParentWriter()
        queue.sync {
            drainAvailableBytes()
            cancelSource()
        }
        completion.wait()
        return queue.sync {
            BoundedProcessOutputSnapshot(
                data: data,
                truncated: truncated
            )
        }
    }

    private func drainAvailableBytes() {
        guard !finished else {
            return
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    readDescriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            if count > 0 {
                append(buffer, count: count)
                continue
            }
            if count == 0 {
                cancelSource()
                return
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN:
                return
            default:
                truncated = true
                cancelSource()
                return
            }
        }
    }

    private func append(_ buffer: [UInt8], count: Int) {
        let remaining = maximumBytes - data.count
        if remaining > 0 {
            data.append(contentsOf: buffer.prefix(min(remaining, count)))
        }
        if count > remaining {
            truncated = true
        }
    }

    private func cancelSource() {
        guard !finished else {
            return
        }
        finished = true
        source?.cancel()
        source = nil
    }

    private static func configure(
        descriptor: Int32,
        nonBlocking: Bool
    ) throws {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
        else {
            throw SandboxRuntimeError.unsupported(
                "failed to secure process output pipe"
            )
        }
        guard nonBlocking else {
            return
        }
        let statusFlags = fcntl(descriptor, F_GETFL)
        guard statusFlags >= 0,
              fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0
        else {
            throw SandboxRuntimeError.unsupported(
                "failed to configure process output pipe"
            )
        }
    }
}
