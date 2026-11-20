import CryptoKit
import Foundation
import Network
import Security

/// The coordinator host and certificate authority keys a build expects of its
/// coordinator connection.
///
/// Once the system's trust evaluation has accepted a `wss://` or `https://`
/// coordinator connection, the provider compares it with the build's pin: the
/// URL's host must be the build's coordinator host, and the certificate chain
/// the system builds for that host must contain an issuing certificate whose
/// key is one of `authorityKeys`. Each kind of difference is logged once per
/// process (`coordinatorHostNotPinned`, `coordinatorCertificateNotPinned`) and
/// nothing else changes: the connection is never refused here.
///
/// The pinned keys belong to certificate authorities, not to the coordinator's
/// own certificate, whose key changes when its certificate is renewed.
enum CoordinatorServerPin {
    struct Pin: Sendable, Equatable {
        /// Host name of the build's coordinator (`normalizedHost`).
        var host: String
        /// Base64 SHA-256 of DER SubjectPublicKeyInfo (the `pin-sha256` form).
        var keys: Set<String>
    }

    enum Difference: Sendable, Hashable {
        case host
        case certificateKey
    }

    /// What a connection's comparison found, as heartbeats report it
    /// (`coordinator_connection_check`).
    enum Report: String, Sendable, Equatable {
        case matches
        case hostDiffers = "host_differs"
        case certificateDiffers = "certificate_differs"
        case hostAndCertificateDiffer = "host_and_certificate_differ"

        init(_ differences: [Difference]) {
            switch (differences.contains(.host), differences.contains(.certificateKey)) {
            case (false, false): self = .matches
            case (true, false): self = .hostDiffers
            case (false, true): self = .certificateDiffers
            case (true, true): self = .hostAndCertificateDiffer
            }
        }
    }

    /// One connection's report, empty until its comparison ends. Each
    /// connection gets its own, so a late result never lands on the next one.
    final class ConnectionReport: @unchecked Sendable {
        private let lock = NSLock()
        private var report: Report?

        var value: Report? { lock.withLock { report } }

        func record(_ report: Report) { lock.withLock { self.report = report } }
    }

    /// The roots the coordinators' certificates chain to today (ISRG, which
    /// runs Let's Encrypt), and the roots of a second ACME authority kept as a
    /// backup (Sectigo, which issues ZeroSSL certificates).
    static let authorityKeys: Set<String> = [
        "C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M=", // ISRG Root X1 (RSA 4096)
        "diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI=", // ISRG Root X2 (ECDSA P-384)
        "sCkq5UWXjg+7mKu9lMhhYF5bGLsy7VI/UNW3tccdR7w=", // Root YE (ISRG, ECDSA P-384)
        "fk6IOKit1ild5647BH06ujSIq5XbCgqlbYl6ANhhi88=", // Root YR (ISRG, RSA 4096)
        "sLVjNUaFYfW7n6EtgBeEpjOlcnBdNPMrZDRF36iwBdE=", // Sectigo Public Server Authentication Root E46
        "Douxi77vs4G+Ib/BogbTFymEYq0QSFXwSgVCaZcI09Q=", // Sectigo Public Server Authentication Root R46
        "ICGRfpgmOUXIWcQ/HXPLQTkFPEFPoDyjvH7ohhQpjzs=", // USERTrust ECC Certification Authority
        "x4QzPSC810K5/cMjb05Qm4k3Bw5zBn4lTdO/nEW/Td4=", // USERTrust RSA Certification Authority
    ]

    static func pin(for environment: BuildEnvironment = .current) -> Pin {
        Pin(host: normalizedHost(URL(string: environment.coordinatorWebSocketURL)), keys: authorityKeys)
    }

    /// The URL's host in lowercase without a trailing dot, or "" without one.
    static func normalizedHost(_ url: URL?) -> String {
        var host = url?.host?.lowercased() ?? ""
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// What differs between a connection to `url` that presented `presented`
    /// (DER, leaf first) and `pin`. The chain is the one the system's trust
    /// evaluation builds for the URL's host; one it does not accept differs.
    static func differences(url: URL, presented: [Data], pin: Pin, at date: Date? = nil) -> [Difference] {
        let host = normalizedHost(url)
        var differences: [Difference] = host == pin.host ? [] : [.host]
        if !carriesPinnedKey(evaluatedChain(presented: presented, host: host, at: date) ?? [], pin: pin) {
            differences.append(.certificateKey)
        }
        return differences
    }

    /// True when an issuing certificate of `chain` (DER, leaf first) has one of
    /// the pinned keys. The leaf is not one: the pins name authorities.
    static func carriesPinnedKey(_ chain: [Data], pin: Pin) -> Bool {
        chain.dropFirst().contains { subjectPublicKeyInfoDigest(certificateDER: $0).map(pin.keys.contains) == true }
    }

    /// The chain (DER, leaf first, anchor last) the system's SSL trust
    /// evaluation builds for `host` from `presented`, or nil when it does not
    /// accept them.
    static func evaluatedChain(presented: [Data], host: String, at date: Date? = nil) -> [Data]? {
        let certificates = presented.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty, certificates.count == presented.count else { return nil }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString),
                                             &trust) == errSecSuccess, let trust else { return nil }
        if let date { SecTrustSetVerifyDate(trust, date as CFDate) }
        guard SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return nil }
        return chain.map { SecCertificateCopyData($0) as Data }
    }

    /// Base64 SHA-256 of the certificate's DER SubjectPublicKeyInfo, or nil
    /// when `der` is not an X.509 certificate.
    static func subjectPublicKeyInfoDigest(certificateDER der: Data) -> String? {
        subjectPublicKeyInfo(certificateDER: der).map { Data(SHA256.hash(data: $0)).base64EncodedString() }
    }

    /// The SubjectPublicKeyInfo element (tag and length included) of an X.509
    /// certificate: Certificate → TBSCertificate → [0] version (optional),
    /// serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo.
    static func subjectPublicKeyInfo(certificateDER der: Data) -> Data? {
        var outer = DERReader(der)
        guard let certificate = outer.next(tag: 0x30) else { return nil }
        var certificateFields = DERReader(certificate.content)
        guard let tbs = certificateFields.next(tag: 0x30) else { return nil }
        var fields = DERReader(tbs.content)
        _ = fields.next(tag: 0xA0) // optional: a v1 certificate has no version field
        for tag: UInt8 in [0x02, 0x30, 0x30, 0x30, 0x30] {
            guard fields.next(tag: tag) != nil else { return nil }
        }
        return fields.next(tag: 0x30)?.element
    }

    /// The kinds of difference a process has logged. A provider that
    /// reconnects to the same coordinator would otherwise repeat them.
    final class LoggedDifferences: @unchecked Sendable {
        private let lock = NSLock()
        private var logged: Set<Difference> = []

        /// True the first time `difference` is offered.
        func isFirst(_ difference: Difference) -> Bool { lock.withLock { logged.insert(difference).inserted } }
    }

    static let logged = LoggedDifferences()

    /// Logs each difference of a ready coordinator connection whose kind
    /// `alreadyLogged` has not seen: a public warning, then the host as a
    /// private line.
    static func log(_ differences: [Difference], host: String, logger: ProviderLogger,
                    alreadyLogged: LoggedDifferences = logged) {
        for difference in differences where alreadyLogged.isFirst(difference) {
            switch difference {
            case .host: logger.warning(.coordinatorHostNotPinned)
            case .certificateKey: logger.warning(.coordinatorCertificateNotPinned)
            }
            logger.warning("coordinator connection to \(host): \(difference) differs from the build's pin")
        }
    }

    /// One evaluation at a time, off the connection's path.
    private static let queue = DispatchQueue(label: "darkbloom.coordinator.server-pin", qos: .utility)

    /// Compares a ready `wss://` or `https://` coordinator connection with the
    /// build's pin off the connection's path, and logs what differs. Returns
    /// the connection's report, which records the result once the comparison
    /// ends and stays empty for a connection without TLS (or when a debug
    /// build skips the comparison).
    static func observe(_ connection: NWConnection, url: URL, logger: ProviderLogger,
                        environment: BuildEnvironment = .current) -> ConnectionReport {
        let report = ConnectionReport()
        #if DEBUG
        // A debug build pinned to a local test coordinator's own certificate.
        if CoordinatorDebugCertificatePin.pinnedDigest(
            ProcessInfo.processInfo.environment[CoordinatorDebugCertificatePin.environmentKey]) != nil { return report }
        #endif
        // Only a `wss://` or `https://` connection runs TLS (`connectionParameters(for:)`).
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return report }
        var presented: [Data] = []
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            presented.append(SecCertificateCopyData(sec_certificate_copy_ref(certificate).takeRetainedValue()) as Data)
        }
        let expected = pin(for: environment)
        queue.async { [presented] in
            let found = differences(url: url, presented: presented, pin: expected)
            report.record(Report(found))
            log(found, host: normalizedHost(url), logger: logger)
        }
        return report
    }
}

/// Reads DER elements one after another. Only definite lengths of up to four
/// length bytes are read; anything else, or another tag, reads as nil and
/// leaves the reader where it was.
private struct DERReader {
    struct Element {
        let element: Data
        let content: Data
    }

    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func next(tag: UInt8) -> Element? {
        guard offset + 1 < data.endIndex, data[offset] == tag else { return nil }
        var cursor = offset + 1
        var length = Int(data[cursor])
        cursor += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard (1...4).contains(count), cursor + count <= data.endIndex else { return nil }
            length = data[cursor..<cursor + count].reduce(0) { $0 << 8 | Int($1) }
            cursor += count
        }
        guard length <= data.endIndex - cursor else { return nil }
        let end = cursor + length
        defer { offset = end }
        return Element(element: data[offset..<end], content: data[cursor..<end])
    }
}
