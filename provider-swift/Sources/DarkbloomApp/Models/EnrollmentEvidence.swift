import Foundation

enum EnrollmentEvidence: Equatable, Sendable {
    case enrolled
    case missing(detail: String)
    case conflicting(detail: String)

    static func evaluate(report: DoctorJSONReport) -> Self {
        if let check = report.check(id: "mdm-enrollment") {
            if check.detail.localizedCaseInsensitiveContains("another MDM") {
                return .conflicting(detail: check.detail)
            }
            return check.status == "pass"
                ? .enrolled
                : .missing(detail: check.detail)
        }
        return .missing(
            detail: "The current system check did not report local MDM enrollment evidence."
        )
    }
}
