import Foundation

struct EnrollmentInstruction: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
}

enum EnrollmentGuide {
    static let profileName = "Darkbloom Provider Enrollment"
    static let administratorApprovalNote = "Authenticate with a macOS administrator account, then return here."

    static let instructions = [
        EnrollmentInstruction(
            id: "select-profile",
            title: "Select the profile",
            detail: "Choose “\(profileName)”."
        ),
        EnrollmentInstruction(
            id: "install-profile",
            title: "Click Install…",
            detail: "macOS will show the profile details."
        ),
        EnrollmentInstruction(
            id: "confirm-install",
            title: "Review and install",
            detail: "Click Install once more to confirm."
        ),
        EnrollmentInstruction(
            id: "administrator-approval",
            title: "Approve as administrator",
            detail: administratorApprovalNote
        ),
    ]
}
