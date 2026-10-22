import Darwin
import Foundation
import Testing
@testable import ProviderCore

@Suite struct GLM5NextCalibrationQuoteOutputTests {
    @Test func writesOneLineAndRestoresDescriptorFlags() throws {
        let pipe = Pipe(), fd = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(fd, F_GETFL), noSignal = fcntl(fd, F_GETNOSIGPIPE)
        let response = Data("{\"ok\":true}".utf8)
        try GLM5NextCalibrationQuoteOutput.write(response, descriptor: fd,
            deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
        #expect(count == response.count + 1)
        #expect(Data(buffer.prefix(max(0, count))) == response + Data([10]))
        // A plain write also changes a kernel-maintained F_GETFL bit. Check
        // the mutable mode this writer changes, separately from SIGPIPE.
        #expect(fcntl(fd, F_GETFL) & O_NONBLOCK == flags & O_NONBLOCK)
        #expect(fcntl(fd, F_GETNOSIGPIPE) == noSignal)
    }

    @Test func fullPipeHasFiniteDeadlineAndRestoresDescriptorFlags() throws {
        let pipe = Pipe(), fd = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(fd, F_GETFL), noSignal = fcntl(fd, F_GETNOSIGPIPE)
        try #require(fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0)
        let fill = [UInt8](repeating: 0x61, count: 4096)
        var filled = false
        for _ in 0..<4096 {
            let count = fill.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { filled = true; break }
            try #require(count > 0)
        }
        try #require(filled)
        try #require(fcntl(fd, F_SETFL, flags) == 0)
        let start = DispatchTime.now().uptimeNanoseconds
        #expect(throws: GLM5NextCalibrationQuoteOutput.Failure.deadline) {
            try GLM5NextCalibrationQuoteOutput.write(Data("{}".utf8), descriptor: fd,
                deadline: start + 100_000_000)
        }
        #expect(DispatchTime.now().uptimeNanoseconds - start < 2_000_000_000)
        #expect(fcntl(fd, F_GETFL) & O_NONBLOCK == flags & O_NONBLOCK)
        #expect(fcntl(fd, F_GETNOSIGPIPE) == noSignal)
    }

    @Test func closedPipeFailsWithoutSIGPIPEAndInvalidInputWritesNothing() throws {
        let pipe = Pipe(), fd = pipe.fileHandleForWriting.fileDescriptor
        try pipe.fileHandleForReading.close()
        #expect(throws: GLM5NextCalibrationQuoteOutput.Failure.output) {
            try GLM5NextCalibrationQuoteOutput.write(Data("{}".utf8), descriptor: fd,
                deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        }
        for response in [Data(), Data(repeating: 32, count: 65_537), Data("{}\n{}".utf8)] {
            #expect(throws: GLM5NextCalibrationQuoteOutput.Failure.invalid) {
                try GLM5NextCalibrationQuoteOutput.write(response, descriptor: fd,
                    deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
            }
        }
    }
}
