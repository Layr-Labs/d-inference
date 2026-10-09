import Foundation
import DarkbloomClusterProtocol

/// Reads a worker's capability record and says plainly when it cannot.
///
/// The record is a closed object: a field, schedule or generation mode this
/// build does not know makes it unreadable, by design. The usual cause is a
/// worker and a darkbloom from different trees, for example a newer worker
/// beside an older darkbloom. The two are released together and must be
/// installed together; a mixed install stops here, before any launch. The
/// decoder's own reason is always included, for the other causes.
enum ClusterCapabilityRecord {
    static func decode(_ data: Data, writtenBy origin: String) throws -> ClusterRuntimeCapability {
        do { return try ClusterRuntimeCapabilityCodec.decode(data) }
        catch {
            throw ClusterConfigurationError.invalid("This darkbloom cannot read the capability record written by \(origin) (\(reason(error))). "
                + "A record is written by the worker it describes. One this darkbloom cannot read usually means the two were not built from the same tree, "
                + "for example a record with a field or a mode this darkbloom does not know. "
                + "Install the darkbloom and the worker of one release on both Macs, then run `darkbloom cluster configure` again.")
        }
    }

    private static func reason(_ error: Error) -> String {
        if case ClusterWorkerProtocolError.invalid(let message) = error { return message }
        return String(describing: error)
    }
}
