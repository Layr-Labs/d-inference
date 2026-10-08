#if NATIVE_PAIR_HARDWARE_EXPERIMENT
import Foundation
import CryptoKit
import Darwin
import Network
import Security

enum PrivateClusterTLSError: Error { case configuration, input, endpoint }

// Public certificate data only; copied once before the existing client starts.
// There is no global trust mutation, fallback after an error, or reusable SecTrust
// object shared between connections. The existing member/release gates remain.
struct PrivateClusterTLSAnchor: Sendable {
    private struct Input: Decodable {
        let schema: String
        let host: String
        let port: Int
        let caDERFile: String
        let caDERSHA256: String
    }
    let host: String
    let port: Int
    let caDERSHA256: String
    private let der: Data

    private static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func read(_ path: String, maximum: Int) throws -> Data {
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path else {
            throw PrivateClusterTLSError.input
        }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PrivateClusterTLSError.input }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, before.st_size <= maximum else { throw PrivateClusterTLSError.input }
        var data = Data(count: Int(before.st_size) + 1), offset = 0
        while offset < data.count {
            let n = data.withUnsafeMutableBytes { p in Darwin.read(fd, p.baseAddress!.advanced(by: offset), p.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw PrivateClusterTLSError.input }
            if n == 0 { break }
            offset += n
        }
        guard offset == Int(before.st_size), fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size else { throw PrivateClusterTLSError.input }
        data.removeLast()
        return data
    }

    static func load(environment: [String: String], endpoint: String, member: Bool) throws -> Self? {
        let path = environment["DARKBLOOM_PRIVATE_CLUSTER_TLS_CONFIG"]
        let pin = environment["DARKBLOOM_PRIVATE_CLUSTER_TLS_SHA256"]
        if path == nil && pin == nil { return nil }
        guard member, let path, let pin, pin.count == 64 else { throw PrivateClusterTLSError.configuration }
        let raw = try read(path, maximum: 8192)
        guard hash(raw) == pin else { throw PrivateClusterTLSError.input }
        let x = try JSONDecoder().decode(Input.self, from: raw)
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              Set(object.keys) == ["schema", "host", "port", "caDERFile", "caDERSHA256"],
              x.schema == "private_cluster_tls_anchor_v1", !x.host.isEmpty, x.host.utf8.count <= 253,
              x.host == x.host.lowercased(), (1...65535).contains(x.port), x.caDERSHA256.count == 64 else {
            throw PrivateClusterTLSError.configuration
        }
        let der = try read(x.caDERFile, maximum: 16384)
        guard hash(der) == x.caDERSHA256,
              SecCertificateCreateWithData(nil, der as CFData) != nil else { throw PrivateClusterTLSError.input }
        let result = Self(host: x.host, port: x.port, caDERSHA256: x.caDERSHA256, der: der)
        guard let url = URL(string: endpoint) else { throw PrivateClusterTLSError.endpoint }
        try result.check(url)
        return result
    }

    private func check(_ url: URL) throws {
        guard url.scheme == "wss", url.host == host, (url.port ?? 443) == port,
              url.user == nil, url.password == nil, url.fragment == nil else { throw PrivateClusterTLSError.endpoint }
    }

    func parameters(for url: URL) throws -> NWParameters {
        try check(url) // Every reconnect repeats the exact immutable URL check.
        let options = NWProtocolTLS.Options()
        let queue = DispatchQueue(label: "dev.darkbloom.private-cluster-tls.verify")
        let capturedDER = der, capturedHost = host
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, supplied, complete in
            let trust = sec_trust_copy_ref(supplied).takeRetainedValue()
            guard let certificate = SecCertificateCreateWithData(nil, capturedDER as CFData) else { complete(false); return }
            var copied: CFArray?
            guard SecTrustCopyPolicies(trust, &copied) == errSecSuccess,
                  let original = copied as? [SecPolicy], !original.isEmpty else { complete(false); return }
            // Keep every original Network.framework policy. Add the SAME URL
            // hostname SSL policy rather than replacing it with BasicX509.
            let policies = original + [SecPolicyCreateSSL(true, capturedHost as CFString)]
            guard SecTrustSetPolicies(trust, policies as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { complete(false); return }
            // Current date, validity, signature, constraints and SSL policies
            // remain Security.framework's decision. No exceptions or fallback.
            var error: CFError?
            complete(SecTrustEvaluateWithError(trust, &error))
        }, queue)
        return NWParameters(tls: options, tcp: NWProtocolTCP.Options())
    }
}
#endif
