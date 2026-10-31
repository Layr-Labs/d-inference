import Foundation

/// The persistent half of a link fix: a root launchd job that puts one port's
/// link-local address back whenever the port has no IPv4 address at all.
///
/// A plain `ifconfig` alias lasts only until macOS next strips the port: on a
/// Mac that shares its internet over the Thunderbolt Bridge that happens on
/// ordinary network changes, not just at a restart. The job is one plist under
/// `/Library/LaunchDaemons`; it runs two system tools and installs no program.
struct ClusterLinkAddressKeeper: Equatable, Sendable {
    /// How often launchd runs the check; also how long the port can be
    /// without its address after macOS removes it.
    static let intervalSeconds = 10

    let interface: String
    let address: ClusterLinkLocalAddress

    /// Nil unless `interface` is a plain interface name.
    init?(interface: String, address: ClusterLinkLocalAddress) {
        guard ClusterLinkName.isInterface(interface) else { return nil }
        self.interface = interface
        self.address = address
    }

    static let directory = "/Library/LaunchDaemons"
    private static let labelPrefix = "io.darkbloom.cluster-link."
    private static let fileSuffix = ".plist"

    static func label(forInterface interface: String) -> String {
        labelPrefix + interface
    }

    static func plistPath(forInterface interface: String) -> String {
        "\(directory)/\(label(forInterface: interface))\(fileSuffix)"
    }

    /// The interfaces that have a keeper's job definition, whatever is in
    /// it, from an `ls` of `directory`. Only names of exactly this shape count.
    static func installedInterfaces(inListing listing: String) -> [String] {
        listing.split(separator: "\n").compactMap { name in
            guard name.hasPrefix(labelPrefix), name.hasSuffix(fileSuffix) else { return nil }
            let interface = String(name.dropFirst(labelPrefix.count).dropLast(fileSuffix.count))
            return ClusterLinkName.isInterface(interface) ? interface : nil
        }
    }

    /// The keeper a job definition is for, when `plutil -convert json` text
    /// is exactly what `installCommands` writes for `interface` with some
    /// link-local address. This is how a keeper is recognised as Darkbloom's
    /// own where the record that named it is gone.
    static func described(byJobJSON text: String, interface: String) -> ClusterLinkAddressKeeper? {
        guard let job = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let script = (job["ProgramArguments"] as? [String])?.last,
              let start = script.range(of: " inet ", options: .backwards)?.upperBound,
              let end = script.range(of: " netmask ", options: .backwards)?.lowerBound, start <= end,
              let address = ClusterLinkLocalAddress(dottedDecimal: String(script[start..<end])),
              let keeper = ClusterLinkAddressKeeper(interface: interface, address: address),
              keeper.isDescribed(byJobJSON: text) else { return nil }
        return keeper
    }

    var label: String { Self.label(forInterface: interface) }
    var plistPath: String { Self.plistPath(forInterface: interface) }

    /// What launchd runs as root at load and every `intervalSeconds`: add the
    /// address only when the port has no IPv4 address at all, so a port that
    /// has any other address keeps just that one. Written without a quote,
    /// so that it can be passed as one single-quoted argument.
    var script: String {
        "/sbin/ifconfig \(interface) | /usr/bin/grep -qw inet || "
            + "/sbin/ifconfig \(interface) inet \(address.dottedDecimal) netmask \(ClusterLinkLocalAddress.netmask) alias"
    }

    var programArguments: [String] { ["/bin/sh", "-c", script] }

    /// The commands, for root and in order, that write the job definition,
    /// add the address and start the job. The definition is built key by key
    /// from the fixed values here: no file a user could have prepared is
    /// ever copied into place. The script is run once before the job is
    /// started, so the address is there even where launchd refuses the job.
    var installCommands: [String] {
        let job = "system/\(label)"
        func insert(_ entry: String) -> String { "/usr/bin/plutil -insert \(entry) \(plistPath)" }
        return [
            // A repair replaces a job that is loaded; a first install has none to stop.
            "/bin/launchctl bootout \(job) 2>/dev/null || true",
            "/bin/rm -f \(plistPath)",
            "/usr/bin/plutil -create xml1 \(plistPath)",
            insert("Label -string \(label)"),
            insert("ProgramArguments -array"),
            insert("ProgramArguments.0 -string \(programArguments[0])"),
            insert("ProgramArguments.1 -string \(programArguments[1])"),
            insert("ProgramArguments.2 -string '\(script)'"),
            insert("RunAtLoad -bool true"),
            insert("StartInterval -integer \(Self.intervalSeconds)"),
            "/usr/sbin/chown root:wheel \(plistPath)",
            "/bin/chmod 644 \(plistPath)",
            "\(programArguments[0]) \(programArguments[1]) '\(script)'",
            // Nothing is written to launchd's own database of enabled and
            // disabled jobs: a removal could not take such an entry out again.
            "/bin/launchctl bootstrap system \(plistPath)",
        ]
    }

    /// Whether `plutil -convert json` text is exactly the job definition that
    /// `installCommands` writes: the same four keys with values of the same
    /// type. A number is not taken for `true`, nor a fraction for the interval.
    func isDescribed(byJobJSON text: String) -> Bool {
        guard let job = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], job.count == 4,
              let runAtLoad = job["RunAtLoad"] as? NSNumber, let interval = job["StartInterval"] as? NSNumber else {
            return false
        }
        return job["Label"] as? String == label && job["ProgramArguments"] as? [String] == programArguments
            && runAtLoad === kCFBooleanTrue && interval !== kCFBooleanTrue && interval !== kCFBooleanFalse
            && !CFNumberIsFloatType(interval) && interval.intValue == Self.intervalSeconds
    }

    /// Whether launchd has the job loaded and its definition on disk is the
    /// one `installCommands` writes. Read with two read-only tools; nil when
    /// one of them could not finish, which says neither.
    func isRunning(run: ClusterLinkToolRunner) -> Bool? {
        let loaded = run(.keeperJob(interface: interface)), written = run(.keeperJobFile(interface: interface))
        for outcome in [loaded, written] where outcome == .timedOut || outcome == .outputTooLarge { return nil }
        guard case .output = loaded, case .output(let definition) = written else { return false }
        return isDescribed(byJobJSON: definition)
    }
}
