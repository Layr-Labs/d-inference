/// The Apple signing identity of the code Darkbloom ships.
///
/// A requirement built here accepts a signature only from a listed Developer
/// ID Application certificate. The Team ID alone does not identify Darkbloom:
/// every Developer ID certificate that Eigen Labs issues, for any product,
/// carries the same Team ID.
public enum DarkbloomSigningIdentity {
    public static let teamID = "SLDQ2GJ6TL"

    /// SHA-1 of the DER encoding of each certificate that may sign Darkbloom
    /// code, in lowercase hexadecimal: the value `certificate leaf = H"…"`
    /// compares.
    ///
    /// Add a replacement certificate here, and let that release reach the
    /// fleet, BEFORE anything is signed with it. An installed provider checks
    /// an update against the list it was compiled with, and an installed fan
    /// helper checks its provider the same way. Keep a retired certificate
    /// listed while a build it signed can still be installed, a fan helper it
    /// signed is still in use, or a provider holds one as rollback material.
    ///
    /// `scripts/test-signing-certificate-pins.py` fails when a copy of the
    /// requirement outside Swift (installer, desktop app, release workflows,
    /// documented check commands) differs from this list.
    public static let certificateSHA1s = [
        // Developer ID Application: Eigen Labs, Inc. (SLDQ2GJ6TL), serial
        // 08B5180DB23D4C0B. Cannot sign after 2027-02-01.
        "95b67556e04653f56ba5411d20d33dd263ef6e2a",
    ]

    /// Code-signing requirement for Darkbloom code signed as `identifier`.
    public static func requirement(identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamID)\" "
            + "and \(certificateClause(certificateSHA1s))"
    }

    /// One certificate is a bare comparison; several are a parenthesized
    /// alternation, because `or` binds more loosely than `and`.
    static func certificateClause(_ sha1s: [String]) -> String {
        let pins = sha1s.map { "certificate leaf = H\"\($0)\"" }
        return pins.count == 1 ? pins[0] : "(" + pins.joined(separator: " or ") + ")"
    }
}
