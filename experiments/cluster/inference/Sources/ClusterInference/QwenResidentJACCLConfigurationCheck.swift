import Foundation

/// Invented environment and reader only; no actual interfaces or files touched.
func checkQwenResidentJACCLConfiguration() throws -> (accepted: [String], rejected: [String]) {
    let matrix = Data("[[null,\"rdma_en1\"],[\"rdma_en1\",null]]".utf8)
    let environment = ["JACCL_RANK": "0", "JACCL_IBV_DEVICES": "/fixture/matrix.json",
                       "JACCL_COORDINATOR": "169.254.70.46:29500"]
    var accepted: [String] = [], rejected: [String] = []
    func require(_ name: String, _ condition: Bool) throws {
        guard condition else { throw ProbeError("Resident JACCL fixture failed: " + name) }
        accepted.append(name)
    }
    func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw ProbeError("Resident JACCL admitted invalid fixture: " + name)
    }
    func make(_ values: [String: String], bytes: Data? = nil) throws -> QwenResidentJACCLConfiguration {
        try .admit(environment: values) { _, _ in bytes ?? matrix }
    }
    var reads: [(String, Int)] = []
    let first = try QwenResidentJACCLConfiguration.admit(environment: environment) { url, cap in
        reads.append((url.path, cap)); return matrix
    }
    try require("preferred environment and bounded single read", reads.count == 1 &&
        reads[0].0 == "/fixture/matrix.json" && reads[0].1 == 4096 && first.rank == 0 &&
        first.receipt.localDevice == "rdma_en1" && first.receipt.deviceMatrixSHA256 == sha256(matrix) &&
        !first.receipt.physicalDeviceIdentityVerified && !first.receipt.physicalTransferQualified)
    let fallback = ["MLX_RANK": "0", "MLX_IBV_DEVICES": "/fixture/matrix.json",
                    "MLX_JACCL_COORDINATOR": "169.254.70.46:29500"]
    try require("native fallback names", try make(fallback).receipt == first.receipt)
    var aliases = environment
    for (key, value) in fallback { aliases[key] = value }
    try require("equal aliases are unambiguous", try make(aliases).receipt == first.receipt)
    var remote = environment
    remote["JACCL_RANK"] = "1"; remote["JACCL_IBV_DEVICES"] = "/other-host/matrix.json"
    let second = try make(remote)
    try require("common fingerprint excludes local rank and path", first.fingerprint == second.fingerprint &&
        second.rank == 1 && second.receipt.deviceMatrixPath != first.receipt.deviceMatrixPath)
    var changed = environment; changed["JACCL_COORDINATOR"] = "169.254.70.46:29501"
    try require("common coordinator changes fingerprint", try make(changed).fingerprint != first.fingerprint)
    try require("all raw matrix bytes bind fingerprint", try make(environment, bytes: matrix + Data([10])).fingerprint != first.fingerprint)
    try first.requireInitialized(rank: 0, worldSize: 2, transport: .jaccl)
    try require("actual backend rank and world match", true)
    try first.requireUnchanged(environment: aliases) { _, _ in matrix }
    try require("equivalent effective aliases pass unchanged check", true)
    let maximum = matrix + Data(repeating: 32, count: 4096 - matrix.count)
    try require("inclusive matrix byte bound", try make(environment, bytes: maximum).receipt.deviceMatrixSHA256 == sha256(maximum))
    enum ReaderFailure: Error { case original }
    do {
        _ = try QwenResidentJACCLConfiguration.admit(environment: environment) { _, _ in throw ReaderFailure.original }
        throw ProbeError("Resident JACCL swallowed its reader error")
    } catch ReaderFailure.original { accepted.append("original reader failure propagates") }

    let pairs = [("JACCL_RANK", "MLX_RANK"), ("JACCL_IBV_DEVICES", "MLX_IBV_DEVICES"),
                 ("JACCL_COORDINATOR", "MLX_JACCL_COORDINATOR")]
    for (preferred, fallback) in pairs {
        var missing = environment; missing.removeValue(forKey: preferred)
        try reject("missing " + preferred) { _ = try make(missing) }
        var empty = environment; empty[preferred] = ""
        try reject("empty preferred " + preferred) { _ = try make(empty) }
        var conflict = aliases; conflict[fallback] = "different"
        try reject("conflicting aliases " + preferred) { _ = try make(conflict) }
    }
    for rank in ["2", "-1", "01", "+1", "1.0", "0 "] {
        var values = environment; values["JACCL_RANK"] = rank
        try reject("rank " + rank) { _ = try make(values) }
    }
    for key in ["JACCL_RING", "MLX_JACCL_RING"] {
        for value in ["", "0"] {
            var values = environment; values[key] = value
            try reject("presence selects ring " + key + "=" + value) { _ = try make(values) }
        }
    }
    for path in ["relative.json", "/fixture/../matrix.json", "/fixture/./matrix.json",
                 "/fixture//matrix.json", "/fixture/", "/fixture/\0matrix.json"] {
        var values = environment; values["JACCL_IBV_DEVICES"] = path
        try reject("matrix path " + String(path.utf8.count)) { _ = try make(values) }
    }
    for endpoint in ["localhost:29500", "::1:29500", "169.254.70.46", "169.254.70.46:0",
                     "169.254.70.46:65536", "169.254.70.46:029500", "169.254.070.46:29500",
                     "0.0.0.0:29500", "224.1.1.1:29500", "169.254.70.256:29500",
                     "169.254.70.46:29500:1", "169.254.70.46:+1"] {
        var values = environment; values["JACCL_COORDINATOR"] = endpoint
        try reject("coordinator " + endpoint) { _ = try make(values) }
    }
    for json in ["", "{}", "[]", "[[null]]", "[[null,\"rdma_en1\"]]",
                 "[[null,\"rdma_en1\"],[null,null]]", "[[0,\"rdma_en1\"],[\"rdma_en1\",null]]",
                 "[[null,true],[\"rdma_en1\",null]]", "[[null,\"\"],[\"rdma_en1\",null]]",
                 "[[null,\"rdma/en1\"],[\"rdma_en1\",null]]", "[[null,NaN],[\"rdma_en1\",null]]"] {
        try reject("matrix schema " + String(json.utf8.count)) { _ = try make(environment, bytes: Data(json.utf8)) }
    }
    try reject("matrix beyond 4 KiB") { _ = try make(environment, bytes: maximum + Data([32])) }
    try reject("effective environment drift") {
        try first.requireUnchanged(environment: remote) { _, _ in matrix }
    }
    try reject("raw matrix drift") {
        try first.requireUnchanged(environment: environment) { _, _ in matrix + Data([10]) }
    }
    for (rank, world, backend) in [(1, 2, ClusterTransport.jaccl), (0, 1, .jaccl), (0, 2, .loopbackTest)] {
        try reject("initialized identity \(rank)/\(world)/\(backend.rawValue)") {
            try first.requireInitialized(rank: rank, worldSize: world, transport: backend)
        }
    }
    var invalidReads = 0
    try reject("invalid environment before IO") {
        _ = try QwenResidentJACCLConfiguration.admit(environment: [:]) { _, _ in
            invalidReads += 1; return matrix
        }
    }
    try require("invalid environment does not call reader", invalidReads == 0)
    guard accepted.count == 11, rejected.count == 55 else {
        throw ProbeError("Resident JACCL configuration fixture count changed")
    }
    return (accepted, rejected)
}
