import Darwin
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

@Suite("Doctor subprocess capture")
struct DoctorCaptureTests {
    @Test("capture retains the complete process table and its final hint")
    func completeLargeOutput() throws {
        let fixture = try DoctorCaptureFixture()
        defer { fixture.cleanup() }
        let bytes = 256 * 1024
        let marker = "\nollama-final-hint\n"
        let result = fixture.capture("print 'x' x \(bytes); print \"\\nollama-final-hint\\n\";")

        // Keep a failure's diagnostics small while comparing every byte.
        let exact = result.output == String(repeating: "x", count: bytes) + marker
        #expect(exact)
        #expect(result.output?.utf8.count == bytes + marker.utf8.count)
        #expect(result.output?.hasSuffix(marker) == true)
        #expect(result.elapsed < 10)
    }

    @Test("stderr beyond pipe capacity cannot become a competing-process hint")
    func stderrIsExcluded() throws {
        let fixture = try DoctorCaptureFixture()
        defer { fixture.cleanup() }
        let result = fixture.capture("""
            print STDERR "ollama LISTEN\\n" x 32768;
            print "stdout-only\\n";
            """)
        #expect(result.output == "stdout-only\n")
        #expect(result.elapsed < 10)
    }

    @Test("contention probes retain useful stdout from a nonzero exit")
    func nonzeroOutput() throws {
        let fixture = try DoctorCaptureFixture()
        defer { fixture.cleanup() }
        let result = fixture.capture("print \"ollama\\n\"; exit 7;")
        #expect(result.output == "ollama\n")
    }

    @Test("shared capture still requires success when no opt-out is supplied")
    func defaultCaptureRejectsNonzeroExit() {
        do {
            _ = try BoundedProcess.runCapturingStandardOutput(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'owned-stdout\\n'; exit 7"],
                timeout: 2)
            Issue.record("default capture accepted a child that exited 7")
        } catch BoundedProcess.Failure.exited(let status, _) {
            #expect(status == 7)
        } catch {
            Issue.record("expected exit status 7, received \(error)")
        }
    }

    @Test("empty stdout remains distinct from a failed capture", arguments: [0, 7])
    func emptyOutput(status: Int) throws {
        let fixture = try DoctorCaptureFixture()
        defer { fixture.cleanup() }
        #expect(fixture.capture("exit \(status);").output == "")
    }

    @Test("invalid UTF-8 preserves the unavailable result")
    func invalidUTF8() throws {
        let fixture = try DoctorCaptureFixture()
        defer { fixture.cleanup() }
        #expect(fixture.capture("print pack('C', 255);").output == nil)
    }

    @Test("a missing executable remains unavailable")
    func missingExecutable() throws {
        let fixture = try DoctorCaptureFixture()
        defer { fixture.cleanup() }
        let missing = fixture.directory.appendingPathComponent("missing-executable")
        #expect(LocalContentionSnapshot.runCapture(missing.path, args: [], timeout: 2) == nil)
    }

    @Test("a hung child is terminated, including when SIGTERM is ignored", arguments: [false, true])
    func hungChild(ignoreTermination: Bool) throws {
        let fixture = try DoctorCaptureFixture()
        defer { fixture.cleanup() }
        let setup = ignoreTermination ? "$SIG{TERM} = 'IGNORE';" : ""
        let timeout: TimeInterval = 2
        let result = fixture.capture("\(setup) sleep 30;", timeout: timeout)
        let pid = try #require(fixture.ownedPID(at: fixture.pidFile))

        #expect(result.output == nil)
        #expect(result.elapsed >= timeout)
        // Allow both existing two-second termination windows and scheduler slack.
        // The fixture's independent 20-second alarm cannot satisfy this bound.
        #expect(result.elapsed < 10)
        let alive = Darwin.kill(pid, 0)
        let probeError = errno
        #expect(alive == -1)
        #expect(probeError == ESRCH)
    }

    @Test("an exited leader does not wait for a descendant to close stdout")
    func inheritedStdoutDoesNotExtendDeadline() throws {
        let fixture = try DoctorCaptureFixture()
        defer { fixture.cleanup() }
        let result = fixture.capture("""
            my $child = fork();
            defined $child or die "fork failed: $!";
            if ($child == 0) {
                # Alarms are not inherited across fork. Bound this owned child too.
                alarm 20;
                record_pid($ARGV[1]);
                sleep 30;
                exit 0;
            }
            # Publish the leader's output only once the descendant holds stdout.
            my $ready_deadline = time() + 5;
            until (-s $ARGV[1]) {
                die "descendant did not become ready" if time() >= $ready_deadline;
                select(undef, undef, undef, 0.01);
            }
            print "leader-complete\\n";
            """, timeout: 2)
        let descendant = try #require(fixture.ownedPID(at: fixture.descendantPIDFile))

        #expect(result.output == "leader-complete\n")
        #expect(result.elapsed < 10)
        // The capture returned while the inherited descriptor was still open.
        #expect(Darwin.kill(descendant, 0) == 0)
    }
}

/// Real children make pipe saturation and termination observable without models.
/// Every child has an independent alarm, so an old blocking implementation can
/// fail these assertions without leaving a test indefinitely stuck in a syscall.
private struct DoctorCaptureFixture {
    let directory: URL
    private let token: String

    var pidFile: URL { directory.appendingPathComponent("child.pid") }
    var descendantPIDFile: URL { directory.appendingPathComponent("descendant.pid") }

    init() throws {
        let token = UUID().uuidString
        self.token = token
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "doctor-capture-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func capture(_ body: String, timeout: TimeInterval = 5) -> (output: String?, elapsed: TimeInterval) {
        let script = """
            use strict;
            use warnings;
            $SIG{ALRM} = 'DEFAULT';
            $SIG{TERM} = 'DEFAULT';
            alarm 20;
            binmode STDOUT;
            binmode STDERR;
            $| = 1;
            sub record_pid {
                my ($path) = @_;
                open(my $file, '>', $path) or die "pid file: $!";
                print {$file} "$$ $ARGV[2]\\n";
                close($file) or die "pid close: $!";
            }
            record_pid($ARGV[0]);
            \(body)
            """
        let started = ProcessInfo.processInfo.systemUptime
        let output = LocalContentionSnapshot.runCapture(
            "/usr/bin/perl",
            args: ["-e", script, pidFile.path, descendantPIDFile.path, token],
            timeout: timeout)
        return (output, ProcessInfo.processInfo.systemUptime - started)
    }

    func ownedPID(at path: URL) -> Int32? {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, fields[1] == token,
              let pid = Int32(fields[0]), pid > 1, pid != getpid() else { return nil }
        return pid
    }

    func cleanup() {
        // Only PID records carrying this fixture's random token are eligible.
        // Kill the forked descriptor holder before removing the parent's record;
        // its alarm is a second bound even if an assertion interrupts the test.
        for path in [descendantPIDFile, pidFile] {
            if let pid = ownedPID(at: path), Darwin.kill(pid, 0) == 0 {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
