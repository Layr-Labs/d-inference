import Darwin

/// A pipe whose ends are closed explicitly.
///
/// The parent must drop the write end after spawning, or its reads never see
/// EOF and the supervisor waits out the whole deadline on a finished command.
struct GuestPipe {
    private(set) var reader: Int32 = -1
    private(set) var writer: Int32 = -1

    mutating func open() -> Bool {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { return false }
        reader = descriptors[0]
        writer = descriptors[1]
        return true
    }

    mutating func closeReader() {
        if reader >= 0 { close(reader); reader = -1 }
    }

    mutating func closeWriter() {
        if writer >= 0 { close(writer); writer = -1 }
    }

    mutating func closeAll() {
        closeReader()
        closeWriter()
    }
}
