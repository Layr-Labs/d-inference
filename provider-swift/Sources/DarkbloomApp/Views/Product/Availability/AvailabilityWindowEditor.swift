import SwiftUI

struct AvailabilityWindowsSection: View {
    let store: AvailabilityStore
    let policy: AvailabilityPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                AvailabilityEditorSectionHeader(
                    title: "Schedule windows",
                    detail: "Multiple windows are supported"
                )
                Spacer()
                Button("Add Window", systemImage: "plus", action: addWindow)
                    .buttonStyle(.bordered)
            }

            if policy.windows.isEmpty {
                emptyState
                    .padding(.top, 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(policy.windows.enumerated()), id: \.element.id) { index, window in
                        if index > 0 {
                            Divider()
                                .padding(.vertical, 18)
                        }
                        AvailabilityWindowRow(
                            store: store,
                            policy: policy,
                            window: window,
                            index: index
                        )
                    }
                }
                .padding(.top, 16)
            }

            Label(
                "Times use \(AvailabilityPresentation.timeZoneTitle(policy.localTimeZone)) and follow future system timezone changes.",
                systemImage: "globe"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 15)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(DarkbloomTheme.accent)
            Text("No availability windows")
                .font(.system(size: 13, weight: .medium))
            Text("Add a window and choose at least one day before saving.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    Color.secondary.opacity(0.22),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        }
    }

    private func addWindow() {
        guard let start = AvailabilityTimeOfDay(hour: 9, minute: 0),
              let end = AvailabilityTimeOfDay(hour: 17, minute: 0)
        else { return }

        store.addWindow(AvailabilityWindow(
            id: UUID().uuidString,
            days: [.monday, .tuesday, .wednesday, .thursday, .friday],
            start: start,
            end: end
        ))
    }
}

private struct AvailabilityWindowRow: View {
    let store: AvailabilityStore
    let policy: AvailabilityPolicy
    let window: AvailabilityWindow
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            windowHeader
            weekdayControls
            timeControls
            validationMessages
        }
    }

    private var windowHeader: some View {
        HStack {
            Text("Window \(index + 1)")
                .font(.system(size: 13, weight: .semibold))

            if window.isOvernight, window.start != window.end {
                Label("Continues into the next day", systemImage: "moon.stars.fill")
                    .font(.caption)
                    .foregroundStyle(DarkbloomTheme.accent)
            }

            Spacer()

            Button("Remove Window", systemImage: "trash", role: .destructive) {
                store.removeWindow(id: window.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help("Remove window \(index + 1)")
        }
    }

    private var weekdayControls: some View {
        HStack(spacing: 6) {
            ForEach(AvailabilityWeekday.allCases, id: \.self) { day in
                Toggle(day.abbreviation, isOn: dayBinding(day))
                    .toggleStyle(.button)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(window.days.contains(day) ? DarkbloomTheme.accent : nil)
                    .accessibilityLabel(dayName(day))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Days for window \(index + 1)")
    }

    private var timeControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 22) {
                timePicker("From", time: window.start, isStart: true)
                timePicker("Until", time: window.end, isStart: false)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                timePicker("From", time: window.start, isStart: true)
                timePicker("Until", time: window.end, isStart: false)
            }
        }
    }

    @ViewBuilder
    private var validationMessages: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Label(
                        AvailabilityPresentation.validationMessage(issue, policy: policy),
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(ProductPalette.critical)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var issues: [AvailabilityPolicyValidationIssue] {
        policy.validation.issues.filter { issue in
            switch issue {
            case .windowHasNoDays(let id), .windowHasEqualStartAndEnd(let id):
                id == window.id
            case .windowsOverlapOrTouch(let firstID, let secondID):
                firstID == window.id || secondID == window.id
            case .scheduleHasNoWindows, .invalidIdleUnloadMinutes:
                false
            }
        }
    }

    private func dayBinding(_ day: AvailabilityWeekday) -> Binding<Bool> {
        Binding(
            get: { window.days.contains(day) },
            set: { isSelected in
                var updated = window
                if isSelected {
                    updated.days.insert(day)
                } else {
                    updated.days.remove(day)
                }
                store.updateWindow(updated)
            }
        )
    }

    private func timePicker(
        _ label: String,
        time: AvailabilityTimeOfDay,
        isStart: Bool
    ) -> some View {
        DatePicker(
            label,
            selection: timeBinding(time, isStart: isStart),
            displayedComponents: [.hourAndMinute]
        )
        .datePickerStyle(.field)
        .fixedSize()
    }

    private func timeBinding(
        _ time: AvailabilityTimeOfDay,
        isStart: Bool
    ) -> Binding<Date> {
        Binding(
            get: { date(for: time) },
            set: { date in
                let calendar = policyCalendar
                let components = calendar.dateComponents([.hour, .minute], from: date)
                guard let updatedTime = AvailabilityTimeOfDay(
                    hour: components.hour ?? time.hour,
                    minute: components.minute ?? time.minute
                ) else { return }

                var updated = window
                if isStart {
                    updated.start = updatedTime
                } else {
                    updated.end = updatedTime
                }
                store.updateWindow(updated)
            }
        )
    }

    private func date(for time: AvailabilityTimeOfDay) -> Date {
        let calendar = policyCalendar
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2001,
            month: 1,
            day: 1,
            hour: time.hour,
            minute: time.minute
        )) ?? .now
    }

    private var policyCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: policy.localTimeZone.identifier) ?? .autoupdatingCurrent
        return calendar
    }

    private func dayName(_ day: AvailabilityWeekday) -> String {
        switch day {
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        case .sunday: "Sunday"
        }
    }
}
