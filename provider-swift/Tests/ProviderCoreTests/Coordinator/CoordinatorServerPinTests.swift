import Foundation
import Security
import Testing
@testable import ProviderCore

/// The coordinator connection is compared with the build's coordinator host and
/// certificate authority keys after the system accepted it; a difference is
/// logged and the connection continues.
@Suite struct CoordinatorServerPinTests {
    /// The chain api.darkbloom.dev served on 2026-11-20: the coordinator's
    /// certificate, Let's Encrypt YE2, Root YE (cross-signed by ISRG Root X2)
    /// and ISRG Root X2 (cross-signed by ISRG Root X1).
    static let servedChain = [
        "MIIDnDCCAyKgAwIBAgISBveGz8fY6tYqALag6mOA5k9mMAoGCCqGSM49BAMDMDMxCzAJBgNVBAYTAlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MQwwCgYDVQQDEwNZRTIwHhcNMjYxMTE0MTYzNzExWhcNMjcwMjEyMTYzNzEwWjAcMRowGAYDVQQDExFhcGkuZGFya2Jsb29tLmRldjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABHfBeyrgR0VYe8rbZQxPvxZNjOEluf0cY82XrlhQCsbz1fvo7m1ZA3eplZ3/d2WkWFeywItXpYYi7cC3HjwNMGqjggIrMIICJzAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQUZwhMKgrKQGBnMEEBX48jsxS4eSYwHwYDVR0jBBgwFoAUuVnyjs8i8IbTN0j/dhQYuoLYVYcwMwYIKwYBBQUHAQEEJzAlMCMGCCsGAQUFBzAChhdodHRwOi8veWUyLmkubGVuY3Iub3JnLzAcBgNVHREEFTATghFhcGkuZGFya2Jsb29tLmRldjATBgNVHSAEDDAKMAgGBmeBDAECATAvBgNVHR8EKDAmMCSgIqAghh5odHRwOi8veWUyLmMubGVuY3Iub3JnLzEwMy5jcmwwggEXBgorBgEEAdZ5AgQCBIIBBwSCAQMBAQB+AFlubDOGlLJZcqJWyKDo3ZBKdugIPdqHOwEIOCgUPO5ZAAABodshGqQACAAABQAlSFxuBAMARzBFAiEApNzEepyLRN2gTiiEmy5wmy4gwC3vshQAiwry9lh0f6QCIArKQsqamFEN8uKgMwIVgEydapxIS/kBmwDvFiNspxKzAH8AROgi/CurDpLu0On61pZkYCd20Bdg4IkFCckjobA/w38AAAGh2yEaXAAIAAAFAB4NLmcEAwBIMEYCIQC0OGWP23g/L1LFv1jkD/PWXmHo+jW+yftu8TNrMP4Y/AIhAM3xFTUlY0U4UAROyfiNi0K1ZefOCzsQlW43tO54dx3VMAoGCCqGSM49BAMDA2gAMGUCMHLgiSShLugSfSjfTq0eIG7HCLPEY2wa2X5gvurl55GNgINPv6P5NIukmP/Xb8pGawIxAMsFa2/UDymCiSoZ8l8tNI3rPMqLsLfGYKFq9cmeKvbHGNVRWqku7JGjewuy1iB/6g==",
        "MIICjDCCAhGgAwIBAgIQTfOxXdbAeExQfNN7WObxFTAKBggqhkjOPQQDAzAuMQswCQYDVQQGEwJVUzENMAsGA1UEChMESVNSRzEQMA4GA1UEAxMHUm9vdCBZRTAeFw0yNTA5MDMwMDAwMDBaFw0yODA5MDIyMzU5NTlaMDMxCzAJBgNVBAYTAlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MQwwCgYDVQQDEwNZRTIwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAARxmrQzkdbEEL3MqXt3dJQttYc47axkdDTHud5TPqM2z5uSD5cmk0WrHlWXvnlvqBLqiB34kluxIbmMyAiq3/YD6e80/vV259K8XQIdjFXloYOa0mIU71f7HQ09PvYDlw+jge4wgeswDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMBMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFLlZ8o7PIvCG0zdI/3YUGLqC2FWHMB8GA1UdIwQYMBaAFKPIJlqOoUzQNWP8myPIOq5W809WMDIGCCsGAQUFBwEBBCYwJDAiBggrBgEFBQcwAoYWaHR0cDovL3llLmkubGVuY3Iub3JnLzATBgNVHSAEDDAKMAgGBmeBDAECATAnBgNVHR8EIDAeMBygGqAYhhZodHRwOi8veWUuYy5sZW5jci5vcmcvMAoGCCqGSM49BAMDA2kAMGYCMQDIcnw5dcZLN9ffynXnnkLD/itSJEycJPb3sRkzeqBowup7vOsAwaqoCnNn/jh9wycCMQCJM6CPlaOC4pQYYbJtVPYbDKrIb2EKk5NpOpE6/XttQYZV/3gilB9l+Cc/DOVwmyg=",
        "MIICpjCCAiugAwIBAgIRAIchZfw0tuX7qK3Vs3BftTowCgYIKoZIzj0EAwMwTzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2VhcmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDIwHhcNMjYwNTEzMDAwMDAwWhcNMzIwOTAyMjM1OTU5WjAuMQswCQYDVQQGEwJVUzENMAsGA1UEChMESVNSRzEQMA4GA1UEAxMHUm9vdCBZRTB2MBAGByqGSM49AgEGBSuBBAAiA2IABDwS/6vhrcVqcbBo+wgdI3fwn9x7DNJJOY/lTOti0vkwuRN87RhEhTH17E7XyFjWsPYhIPt/wzOqxTd2b+4ZJNy9ID04YywF9U5zasDVyGSNErVNtz8uSGh5izW87j77GaOB6zCB6DAOBgNVHQ8BAf8EBAMCAQYwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUo8gmWo6hTNA1Y/ybI8g6rlbzT1YwHwYDVR0jBBgwFoAUfEKWrt5LSDv6kviejM9ti6lyN5UwMgYIKwYBBQUHAQEEJjAkMCIGCCsGAQUFBzAChhZodHRwOi8veDIuaS5sZW5jci5vcmcvMBMGA1UdIAQMMAowCAYGZ4EMAQIBMCcGA1UdHwQgMB4wHKAaoBiGFmh0dHA6Ly94Mi5jLmxlbmNyLm9yZy8wCgYIKoZIzj0EAwMDaQAwZgIxAMU19WCtmxVND8UHBZRoma49Z7jPs64Dma0eTu1OChVbB/2J7GV3nvYKAx54uk1G9QIxAO0miLVJu8PLNiXXXkiE/gsK3CTRTF/aeo4bMX42Zw40csRU6AC26hSW1/IWaas6dg==",
        "MIIEcDCCAligAwIBAgIQbI8dxyfHEX97r4U6yYD5zTANBgkqhkiG9w0BAQsFADBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJuZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBYMTAeFw0yNjA1MTMwMDAwMDBaFw0zMjA5MDIyMzU5NTlaME8xCzAJBgNVBAYTAlVTMSkwJwYDVQQKEyBJbnRlcm5ldCBTZWN1cml0eSBSZXNlYXJjaCBHcm91cDEVMBMGA1UEAxMMSVNSRyBSb290IFgyMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEzZvVn4CDCuwJSvMWSj5cz3es3mcFDR0HttwW+1qLFNvicWDEukWVEYmO6gbf9yoWHKS5xcUy4APgHoIYOIvXRdgKam7mAHf7AlF9ItgKbppbd9/w+kHsOdx1ymgHDB/qo4H1MIHyMA4GA1UdDwEB/wQEAwIBBjAdBgNVHSUEFjAUBggrBgEFBQcDAQYIKwYBBQUHAwIwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUfEKWrt5LSDv6kviejM9ti6lyN5UwHwYDVR0jBBgwFoAUebRZ5nu25eQBc4AIiMgaWPbpm24wMgYIKwYBBQUHAQEEJjAkMCIGCCsGAQUFBzAChhZodHRwOi8veDEuaS5sZW5jci5vcmcvMBMGA1UdIAQMMAowCAYGZ4EMAQIBMCcGA1UdHwQgMB4wHKAaoBiGFmh0dHA6Ly94MS5jLmxlbmNyLm9yZy8wDQYJKoZIhvcNAQELBQADggIBAD2/e9frmMxNpCV03qUHegg+MV2wz9644YoXdqtH8RyWYcBO7xfjjGEXdU1e/o0OkEFiynUCOSIk/vLLo7ttz6CPAeNlWfC0XNkoGeWgK6jjXvozBaGuGH5n0UfoshMeWTuURqNN5G00sSXDTBrpp2+mgvdZQjb8K11TYMA25QA+YHNfbIEL0BniAhKS2gsnJjSzrdZLI+EZ7SEyqdR2rkjd1KutLDU+n3TFyxjniZVGur4YlhMP3mY/dV95IruAkkjOZier6hGBdEgZXXvaCz9u9iVEadsIE75pAGL8oHV5vxdARDiotRpul1IN/UZwzAbrfUFcw1HkAcYD/mlZfnQ2ieCF2MS7j3Vhv7JPDKp45fmykmzYNSrumRW0upFFKDBOoF7hsOb7oLyHS+Uft6jOUfOrogj8YUx38hKb2K20r42OgsSdDdxdeYWcMS3Sb6mwJeSZEYxJ2gaXnDSPaKhhrNkYwljyVQyr4Nq+MEJytXNTnHqaAcrNwZlVpcJL1KBnMrMjP7eanvUwL3FYj3cF17jtboLt7gLoi4+2rWZFvn+w54jmd/FIuhhZcEaU/wvU6BUNMtcVquVGHp7itQeDth5j+XL3j4WJ2SABwzUl6OeYdgpIt/ITZa+pTT0mQ/r5XyA4MEAiabn7XJjvCERlF2dcn2wqJw+CreTkkQ2R",
    ].map { Data(base64Encoded: $0)! }

    /// A root made for this test and a certificate for api.darkbloom.dev it
    /// issued: what a Mac that trusts an added root could be shown.
    static let localRoot = Data(base64Encoded: "MIIBVTCB/KADAgECAgkArsd/BeTt1VEwCgYIKoZIzj0EAwIwHTEbMBkGA1UEAwwSRXhhbXBsZSBMb2NhbCBSb290MCAXDTI2MTEyMDAxMjUzMloYDzIxMjYxMDI3MDEyNTMyWjAdMRswGQYDVQQDDBJFeGFtcGxlIExvY2FsIFJvb3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASKz+XEuKOE28+X9l//Uwm2asjkcnZvg+OEBthYE6ov/YYlfuCcs1uPdzOljcAzJ2C9zHgv46k3jsPlgFkrFqOkoyMwITAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAKBggqhkjOPQQDAgNIADBFAiA4Y6VQ1yZ/QNtBUQaCVgqwlFdXtrKl6raQ4z2WN+9zJwIhALiNthBr82Yxti5YNDL1OTzIZVhq6R03tfPe3/gLo/hF")!
    static let localLeaf = Data(base64Encoded: "MIIBgDCCASagAwIBAgIJAMIoBPrDxDbUMAoGCCqGSM49BAMCMB0xGzAZBgNVBAMMEkV4YW1wbGUgTG9jYWwgUm9vdDAeFw0yNjExMjAwMTI1NDlaFw0yNzA5MTYwMTI1NDlaMBwxGjAYBgNVBAMMEWFwaS5kYXJrYmxvb20uZGV2MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEabFKRX8FBNRAgxhIvio6zTKwaYsJVG4jRPwJqXjD6fzxsAQ9gLPIuFhVHeNo2AK33uNyBAAsPZKmcEwBJ0pJ8KNQME4wCQYDVR0TBAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwHAYDVR0RBBUwE4IRYXBpLmRhcmtibG9vbS5kZXYwCgYIKoZIzj0EAwIDSAAwRQIhAIWI6aO8Zdz03eF57r+jxDLuQ+htoIFODzbr8bgeDOUxAiAfZBSW+ooelTsJBYw2xWJ4CexvD7UpsKnc3MG3Xd4tpw==")!

    /// Inside every fixture certificate's validity.
    static let evaluationDate = ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")!
    static let coordinator = URL(string: "wss://api.darkbloom.dev/ws/provider")!

    @Test func eachEnvironmentPinsItsOwnCoordinatorHost() {
        #expect(CoordinatorServerPin.pin(for: .prod).host == "api.darkbloom.dev")
        #expect(CoordinatorServerPin.pin(for: .dev).host == "api.dev.darkbloom.dev")
        #expect(CoordinatorServerPin.pin(for: .staging).host == "api.staging.darkbloom.dev")
        for environment in BuildEnvironment.allCases {
            #expect(CoordinatorServerPin.pin(for: environment).keys == CoordinatorServerPin.authorityKeys)
        }
    }

    @Test func everyPinnedKeyIsASHA256Digest() {
        #expect(CoordinatorServerPin.authorityKeys.count == 8)
        for key in CoordinatorServerPin.authorityKeys {
            #expect(Data(base64Encoded: key)?.count == 32, "\(key)")
        }
    }

    /// The digests match `openssl x509 -pubkey | openssl pkey -pubin -outform der | sha256 | base64`.
    @Test func theKeyDigestIsOfTheSubjectPublicKeyInfo() {
        let expected = [
            "FAF/maFq3S/CzV7v/BcngjqpeR6+GYzjEYdwuYivuZw=", // api.darkbloom.dev
            "s/tdAOmUzd8syaTuqfgGvFcn6DzA5Cmb+Vby1ST+U3Y=", // Let's Encrypt YE2
            "sCkq5UWXjg+7mKu9lMhhYF5bGLsy7VI/UNW3tccdR7w=", // Root YE
            "diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI=", // ISRG Root X2
        ]
        #expect(Self.servedChain.map { CoordinatorServerPin.subjectPublicKeyInfoDigest(certificateDER: $0) } == expected)
    }

    @Test(arguments: [Data(), Data([0x30]), Data([0x30, 0x82, 0xFF]), Data([0x30, 0x03, 0x02, 0x01, 0x00]),
                      Data([0x30, 0x85, 0x01, 0x00, 0x00, 0x00, 0x00])])
    func aMalformedCertificateHasNoKeyDigest(der: Data) {
        #expect(CoordinatorServerPin.subjectPublicKeyInfoDigest(certificateDER: der) == nil)
    }

    @Test func theServedChainMatchesTheProductionPin() throws {
        let chain = try #require(CoordinatorServerPin.evaluatedChain(
            presented: Self.servedChain, host: "api.darkbloom.dev", at: Self.evaluationDate))
        #expect(CoordinatorServerPin.carriesPinnedKey(chain, pin: CoordinatorServerPin.pin(for: .prod)))
        #expect(CoordinatorServerPin.differences(url: Self.coordinator, presented: Self.servedChain,
                                                 pin: CoordinatorServerPin.pin(for: .prod), at: Self.evaluationDate) == [])
        // Host case, an explicit port and a trailing dot name the same coordinator.
        for url in ["wss://API.darkbloom.dev:443/ws/provider", "wss://api.darkbloom.dev./ws/provider"] {
            #expect(CoordinatorServerPin.differences(url: URL(string: url)!, presented: Self.servedChain,
                                                     pin: CoordinatorServerPin.pin(for: .prod), at: Self.evaluationDate) == [],
                    "\(url)")
        }
    }

    /// The pins name authorities: only an issuing certificate matches, never the leaf.
    @Test func onlyAnIssuingCertificateMatchesAPin() {
        let pin = CoordinatorServerPin.pin(for: .prod)
        let rootX2 = Self.servedChain[3]
        #expect(!CoordinatorServerPin.carriesPinnedKey([rootX2], pin: pin))
        #expect(CoordinatorServerPin.carriesPinnedKey([Self.servedChain[0], rootX2], pin: pin))
        #expect(!CoordinatorServerPin.carriesPinnedKey(Array(Self.servedChain.prefix(2)), pin: pin))
    }

    @Test func anotherHostIsADifference() {
        #expect(CoordinatorServerPin.differences(url: Self.coordinator, presented: Self.servedChain,
                                                 pin: CoordinatorServerPin.pin(for: .dev), at: Self.evaluationDate) == [.host])
        #expect(CoordinatorServerPin.differences(url: URL(string: "wss://relay.example/ws/provider")!,
                                                 presented: Self.servedChain,
                                                 pin: CoordinatorServerPin.pin(for: .prod), at: Self.evaluationDate)
                .contains(.host))
    }

    /// A chain the system accepts only through an added root carries none of
    /// the pinned keys.
    @Test func aChainToAnAddedRootIsADifference() throws {
        let leaf = try #require(SecCertificateCreateWithData(nil, Self.localLeaf as CFData))
        let root = try #require(SecCertificateCreateWithData(nil, Self.localRoot as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates([leaf] as CFArray, SecPolicyCreateSSL(true, "api.darkbloom.dev" as CFString),
                                               &trust) == errSecSuccess)
        let added = try #require(trust)
        SecTrustSetAnchorCertificates(added, [root] as CFArray)
        SecTrustSetVerifyDate(added, Self.evaluationDate as CFDate)
        #expect(SecTrustEvaluateWithError(added, nil))
        let chain = try #require(SecTrustCopyCertificateChain(added) as? [SecCertificate]).map { SecCertificateCopyData($0) as Data }
        #expect(chain.count == 2)
        #expect(!CoordinatorServerPin.carriesPinnedKey(chain, pin: CoordinatorServerPin.pin(for: .prod)))
        // Without the added root the system accepts no chain for it at all.
        #expect(CoordinatorServerPin.evaluatedChain(presented: [Self.localLeaf], host: "api.darkbloom.dev",
                                                    at: Self.evaluationDate) == nil)
        #expect(CoordinatorServerPin.differences(url: Self.coordinator, presented: [Self.localLeaf],
                                                 pin: CoordinatorServerPin.pin(for: .prod), at: Self.evaluationDate)
                == [.certificateKey])
    }

    @Test func aChainTheSystemRefusesIsADifference() {
        let expired = ISO8601DateFormatter().date(from: "2027-06-01T00:00:00Z")!
        #expect(CoordinatorServerPin.differences(url: Self.coordinator, presented: Self.servedChain,
                                                 pin: CoordinatorServerPin.pin(for: .prod), at: expired) == [.certificateKey])
        #expect(CoordinatorServerPin.differences(url: Self.coordinator, presented: [],
                                                 pin: CoordinatorServerPin.pin(for: .prod)) == [.certificateKey])
    }

    /// Each kind of difference is one public warning and one private line with
    /// the host, once per process: a reconnect does not repeat it.
    @Test func eachDifferenceIsLoggedOnce() {
        let lines = LockedLines()
        let logger = ProviderLogger(subsystem: "test", category: "pin", sink: { level, visibility, message in
            lines.append("\(level)|\(visibility)|\(message)")
        })
        let logged = CoordinatorServerPin.LoggedDifferences()
        CoordinatorServerPin.log([], host: "relay.example", logger: logger, alreadyLogged: logged)
        #expect(lines.snapshot().isEmpty)
        CoordinatorServerPin.log([.host], host: "relay.example", logger: logger, alreadyLogged: logged)
        CoordinatorServerPin.log([.host, .certificateKey], host: "relay.example", logger: logger, alreadyLogged: logged)
        CoordinatorServerPin.log([.host, .certificateKey], host: "relay.example", logger: logger, alreadyLogged: logged)
        #expect(lines.snapshot() == [
            "warning|public|\(ProviderOperationalMessage.coordinatorHostNotPinned.text)",
            "warning|private|coordinator connection to relay.example: host differs from the build's pin",
            "warning|public|\(ProviderOperationalMessage.coordinatorCertificateNotPinned.text)",
            "warning|private|coordinator connection to relay.example: certificateKey differs from the build's pin",
        ])
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func snapshot() -> [String] { lock.withLock { lines } }
}
