import Foundation
import SandboxRuntime

/// launchctl print lazily recreates an empty user domain on qualified macOS.
/// This is a strict parser for that observed format, not a general launchd API.
enum GuestEmptyUserDomain {
    static func matches(_ result: SandboxProcessResult) -> Bool {
        guard result.exitCode == 0, !result.standardOutputTruncated, !result.standardErrorTruncated,
              result.standardError.isEmpty, result.standardOutput.count <= 65536,
              let text = String(data: result.standardOutput, encoding: .utf8), !text.contains("\r"),
              !text.contains("\0") else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count <= 512, lines.first == "user/2001 = {", lines.last == "}" else { return false }
        var fields: [String: String] = [:]
        var blocks: [String: [String]] = [:]
        var index = 1
        while index < lines.count - 1 {
            let line = lines[index]
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t"),
                  let separator = line.range(of: " = ") else { return false }
            let key = String(line[line.index(after: line.startIndex)..<separator.lowerBound])
            let value = String(line[separator.upperBound...])
            guard fields[key] == nil, blocks[key] == nil else { return false }
            if value == "{" {
                var body: [String] = []
                index += 1
                while index < lines.count - 1, lines[index] != "\t}" {
                    guard lines[index].hasPrefix("\t\t"), !lines[index].contains("{"), !lines[index].contains("}")
                    else { return false }
                    body.append(lines[index])
                    index += 1
                }
                guard index < lines.count - 1, lines[index] == "\t}" else { return false }
                blocks[key] = body
            } else {
                guard !value.contains("{"), !value.contains("}") else { return false }
                fields[key] = value
            }
            index += 1
        }
        let emptySections = ["services", "unmanaged processes", "endpoints"]
        guard Set(blocks.keys) == Set(emptySections + ["security context", "task-special ports"]),
              emptySections.allSatisfy({ blocks[$0]?.isEmpty == true }),
              Set(fields.keys) == ["type", "handle", "active count", "creator", "creator euid", "session",
                                   "external activation count", "death port", "in-progress bootstraps", "properties"],
              fields["type"] == "user", fields["handle"] == "2001", fields["session"] == "Background",
              fields["death port"] == "0x0", validCreator(fields["creator"] ?? ""),
              ["active count", "creator euid", "external activation count", "in-progress bootstraps"]
                .allSatisfy({ decimal(fields[$0] ?? "") }),
              validProperties(fields["properties"] ?? ""),
              let security = blocks["security context"], security.count == 2,
              security[0] == "\t\tuid = 2001", security[1].hasPrefix("\t\tasid = "),
              decimal(String(security[1].dropFirst("\t\tasid = ".count))),
              let ports = blocks["task-special ports"], ports.count == 2,
              validPort(ports[0], number: "4", name: "bootstrap", target: "com.apple.xpc.launchd.domain.user.2001"),
              validPort(ports[1], number: "9", name: "access", target: "(unknown)") else { return false }
        return true
    }

    private static func decimal(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } && UInt64(value) != nil
    }

    private static func validCreator(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_.-]+\\[[0-9]+\\]$", options: .regularExpression) != nil
    }

    private static func validProperties(_ value: String) -> Bool {
        if value.isEmpty { return true }
        let flags = value.components(separatedBy: " | ")
        return Set(flags).count == flags.count && flags.allSatisfy { ["shutting down", "slain"].contains($0) }
    }

    private static func validPort(_ value: String, number: String, name: String, target: String) -> Bool {
        let fields = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 4, fields[1] == number, fields[2] == name, fields[3] == target,
              fields[0].hasPrefix("0x"), fields[0].count > 2 else { return false }
        return UInt64(fields[0].dropFirst(2), radix: 16) != nil
    }
}
