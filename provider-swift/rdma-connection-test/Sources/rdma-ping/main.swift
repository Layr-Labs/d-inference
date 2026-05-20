import Foundation
import MLX
import Cmlx

// MARK: - CLI args

struct Args {
    var rank: Int = -1
    var size: Int = 2
    var coordinator: String = ""
    var rdmaDevice: String = ""
    var rounds: Int = 20
}

func parseArgs() -> Args {
    var a = Args()
    var i = 1
    let argv = CommandLine.arguments
    while i < argv.count {
        switch argv[i] {
        case "--rank":        i += 1; a.rank = Int(argv[i]) ?? -1
        case "--size":        i += 1; a.size = Int(argv[i]) ?? 2
        case "--coordinator": i += 1; a.coordinator = argv[i]
        case "--rdma-device": i += 1; a.rdmaDevice = argv[i]
        case "--rounds":      i += 1; a.rounds = Int(argv[i]) ?? 20
        case "--help", "-h":
            print("""
            rdma-ping — jaccl/RDMA smoke test

            --rank <N>           This machine's rank (0 = coordinator)
            --size <N>           Total ranks (default: 2)
            --coordinator <addr> Rank 0's IP:port (e.g. 169.254.106.209:9999)
            --rdma-device <dev>  RDMA interface (e.g. rdma_en2); auto-detected if omitted
            --rounds <N>         all_sum rounds (default: 20)
            """)
            exit(0)
        default: break
        }
        i += 1
    }
    return a
}

func fail(_ msg: String) -> Never {
    fputs("error: \(msg)\n", stderr)
    exit(1)
}

func autoDetectDevice() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "ibv_devices 2>/dev/null | awk 'NR>2 {print $1}' | head -1"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

func buildMesh(size: Int, device: String) -> String {
    var rows: [String] = []
    for src in 0 ..< size {
        let cols = (0 ..< size).map { dst in src == dst ? "null" : "\"\(device)\"" }
        rows.append("  [\(cols.joined(separator: ", "))]")
    }
    return "[\n\(rows.joined(separator: ",\n"))\n]\n"
}

// MARK: - main

let args = parseArgs()

guard args.rank >= 0 else { fail("--rank is required") }
guard !args.coordinator.isEmpty else { fail("--coordinator is required") }

let device = args.rdmaDevice.isEmpty ? autoDetectDevice() : args.rdmaDevice
guard !device.isEmpty else { fail("no RDMA device found; pass --rdma-device explicitly") }

let devicesPath = "/tmp/rdma-ping-devices-\(args.rank).json"
let mesh = buildMesh(size: args.size, device: device)
try! mesh.write(toFile: devicesPath, atomically: true, encoding: .utf8)

setenv("MLX_RANK", "\(args.rank)", 1)
setenv("MLX_JACCL_COORDINATOR", args.coordinator, 1)
setenv("MLX_IBV_DEVICES", devicesPath, 1)
setenv("MLX_JACCL_RING", "0", 1)

print("[rdma-ping] rank \(args.rank)/\(args.size)  coordinator=\(args.coordinator)  device=\(device)")
print("[rdma-ping] initializing jaccl…")

let g = mlx_distributed_init(false, nil)
guard g.ctx != nil else {
    fail("jaccl init failed — check: macOS 26.2+, RDMA enabled in Recovery, cable connected")
}

let rank = Int(mlx_distributed_group_rank(g))
let size = Int(mlx_distributed_group_size(g))
print("[rdma-ping] jaccl up — rank=\(rank) size=\(size)")

// Warm-up
let warmupInput = MLXArray(Float(rank))
var warmupRes = mlx_array_new()
mlx_distributed_all_sum(&warmupRes, warmupInput.ctx, g, StreamOrDevice.cpu.ctx)
mlx_array_eval(warmupRes)

// Timed rounds
var totalNs: UInt64 = 0
var allOK = true

print("[rdma-ping] running \(args.rounds) all_sum rounds…")
for i in 0 ..< args.rounds {
    let input = MLXArray(Float(i))
    var resultRaw = mlx_array_new()

    let t0 = DispatchTime.now().uptimeNanoseconds
    mlx_distributed_all_sum(&resultRaw, input.ctx, g, StreamOrDevice.cpu.ctx)
    mlx_array_eval(resultRaw)
    let dt = DispatchTime.now().uptimeNanoseconds - t0
    totalNs += dt

    let result = MLXArray(resultRaw)
    let got = result.item(Float.self)
    let expected = Float(size * i)
    let ok = abs(got - expected) < 0.5
    if !ok { allOK = false }
    let us = String(format: "%.1f", Double(dt) / 1000.0)
    print("  [\(i+1)/\(args.rounds)] \(us)µs  result=\(got) expected=\(expected) [\(ok ? "OK" : "MISMATCH")]")
}

let avgUs = Double(totalNs) / Double(args.rounds) / 1000.0
print("")
print("[rdma-ping] avg latency: \(String(format: "%.1f", avgUs))µs")
print("[rdma-ping] \(allOK ? "ALL OK ✓" : "FAILURES DETECTED ✗")")
