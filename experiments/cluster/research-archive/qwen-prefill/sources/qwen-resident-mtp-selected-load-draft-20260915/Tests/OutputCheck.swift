import Darwin
import Foundation

enum WorkerFailure: Error { case invalid(String) }
func require(_ value: Bool) { precondition(value) }
func pair() -> [Int32] {
    var values: [Int32] = [-1, -1]
    require(pipe(&values) == 0); return values
}
func rejected(_ body: () throws -> Void) {
    do { try body(); preconditionFailure("Invalid output accepted") } catch {}
}

@main enum OutputCheck {
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        let fds = pair()
        defer { close(fds[0]); close(fds[1]) }
        let output = try SelectedLoadOutput(descriptor: fds[1],
            deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        try output.write(Data("{\"type\":\"admitted\"}".utf8))
        try output.write(Data("{\"type\":\"report\"}".utf8))
        rejected { try output.write(Data("{}".utf8)) }
        var bytes = [UInt8](repeating: 0, count: 1024)
        let n = read(fds[0], &bytes, bytes.count)
        require(n > 0 && String(decoding: bytes.prefix(n), as: UTF8.self)
            == "{\"type\":\"admitted\"}\n{\"type\":\"report\"}\n")
        for value in [Data(), Data("{}\n{}".utf8), Data("\r".utf8), Data(repeating: 1, count: 8_388_609)] {
            let fds = pair(); defer { close(fds[0]); close(fds[1]) }
            let output = try SelectedLoadOutput(descriptor: fds[1],
                deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
            rejected { try output.write(value) }
        }
        do {
            let fds = pair(); close(fds[0]); defer { close(fds[1]) }
            let output = try SelectedLoadOutput(descriptor: fds[1],
                deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
            rejected { try output.write(Data("{}".utf8)) }
        }
        do {
            let fds = pair(); defer { close(fds[0]); close(fds[1]) }
            let start = DispatchTime.now().uptimeNanoseconds
            let output = try SelectedLoadOutput(descriptor: fds[1], deadline: start + 30_000_000)
            rejected { try output.write(Data(repeating: 120, count: 8_000_000)) }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            require(elapsed >= 30_000_000 && elapsed < 2_000_000_000)
        }
        do {
            let fds = pair(); defer { close(fds[0]); close(fds[1]) }
            let output = try SelectedLoadOutput(descriptor: fds[1], deadline: 0)
            rejected { try output.write(Data("{}".utf8)) }
        }
        print("output: eight groups passed; real local pipes, no network/native work")
    }
}
