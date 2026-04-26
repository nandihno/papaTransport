import SwiftUI

private struct NotificationScheduleWeekday: Identifiable {
    let calendarWeekday: Int
    let name: String

    var id: Int { calendarWeekday }
}

struct TrainNotificationScheduleView: View {
    @AppStorage(TrainStatusNotificationService.selectedWeekdaysKey) private var weekdayMask = TrainStatusNotificationService.defaultWeekdayMask
    @AppStorage(TrainStatusNotificationService.timesKey) private var timesRaw = TrainStatusNotificationService.encodeTimes([TrainStatusNotificationService.defaultTimeSeconds])

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette

    @State private var timeEditorMode: TimeEditorMode?

    private let weekdays = [
        NotificationScheduleWeekday(calendarWeekday: 2, name: "Monday"),
        NotificationScheduleWeekday(calendarWeekday: 3, name: "Tuesday"),
        NotificationScheduleWeekday(calendarWeekday: 4, name: "Wednesday"),
        NotificationScheduleWeekday(calendarWeekday: 5, name: "Thursday"),
        NotificationScheduleWeekday(calendarWeekday: 6, name: "Friday"),
        NotificationScheduleWeekday(calendarWeekday: 7, name: "Saturday"),
        NotificationScheduleWeekday(calendarWeekday: 1, name: "Sunday")
    ]

    private var times: [Int] {
        TrainStatusNotificationService.decodeTimes(timesRaw)
    }

    var body: some View {
        List {
            Section {
                ForEach(weekdays) { weekday in
                    Toggle(weekday.name, isOn: weekdayBinding(for: weekday.calendarWeekday))
                }
            } header: {
                Text("Active Days")
            } footer: {
                Text("Select which days you want to receive train status notifications.")
            }

            Section {
                presetButton(title: "Weekdays", weekdays: 2...6)
                presetButton(title: "Weekends", weekdays: [1, 7])
                presetButton(title: "Every Day", weekdays: 1...7)
                Button(role: .destructive) {
                    weekdayMask = 0
                    scheduleDidChange()
                } label: {
                    Label("Clear Days", systemImage: "xmark.circle.fill")
                }
            }

            Section {
                ForEach(times, id: \.self) { seconds in
                    HStack(spacing: 14) {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(.orange)
                            .frame(width: 24)

                        Text(timeString(seconds))
                            .font(.body)

                        Spacer()

                        Button {
                            timeEditorMode = .edit(originalSeconds: seconds)
                        } label: {
                            Image(systemName: "pencil.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.accent)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            deleteTime(seconds)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

                Button {
                    timeEditorMode = .add
                } label: {
                    Label("Add Notification Time", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Notification Times (\(times.count))")
            } footer: {
                Text("Add as many daily notification times as you need. Swipe left to delete a time.")
            }

            if weekdayMask == 0 || times.isEmpty {
                Section {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Train Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $timeEditorMode) { mode in
            NotificationTimeEditor(
                mode: mode,
                onSave: { seconds in
                    saveTime(seconds, mode: mode)
                }
            )
        }
    }

    private var validationMessage: String {
        if weekdayMask == 0 {
            return "Select at least one active day."
        }
        return "Add at least one notification time."
    }

    private var scheduledCombinationCount: Int {
        let dayCount = (1...7).filter { weekdayMask & (1 << $0) != 0 }.count
        return dayCount * times.count
    }

    private func weekdayBinding(for calendarWeekday: Int) -> Binding<Bool> {
        Binding {
            weekdayMask & (1 << calendarWeekday) != 0
        } set: { isSelected in
            if isSelected {
                weekdayMask |= (1 << calendarWeekday)
            } else {
                weekdayMask &= ~(1 << calendarWeekday)
            }
            scheduleDidChange()
        }
    }

    private func presetButton<T: Sequence>(title: String, weekdays: T) -> some View where T.Element == Int {
        Button {
            weekdayMask = mask(for: weekdays)
            scheduleDidChange()
        } label: {
            Label(title, systemImage: "calendar")
        }
    }

    private func mask<T: Sequence>(for weekdays: T) -> Int where T.Element == Int {
        weekdays.reduce(0) { $0 | (1 << $1) }
    }

    private func saveTime(_ seconds: Int, mode: TimeEditorMode) {
        var updatedTimes = times

        if case .edit(let originalSeconds) = mode {
            updatedTimes.removeAll { $0 == originalSeconds }
        }

        updatedTimes.append(seconds)
        timesRaw = TrainStatusNotificationService.encodeTimes(updatedTimes)
        scheduleDidChange()
    }

    private func deleteTime(_ seconds: Int) {
        timesRaw = TrainStatusNotificationService.encodeTimes(times.filter { $0 != seconds })
        scheduleDidChange()
    }

    private func scheduleDidChange() {
        Task { await TrainStatusNotificationService.shared.settingsDidChange() }
    }

    private func timeString(_ seconds: Int) -> String {
        let date = NotificationTimeEditor.date(for: seconds)
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private enum TimeEditorMode: Identifiable {
    case add
    case edit(originalSeconds: Int)

    var id: String {
        switch self {
        case .add:
            return "add"
        case .edit(let originalSeconds):
            return "edit-\(originalSeconds)"
        }
    }

    var title: String {
        switch self {
        case .add:
            return "Add Time"
        case .edit:
            return "Edit Time"
        }
    }

    var initialSeconds: Int {
        switch self {
        case .add:
            return TrainStatusNotificationService.defaultTimeSeconds
        case .edit(let originalSeconds):
            return originalSeconds
        }
    }
}

private struct NotificationTimeEditor: View {
    let mode: TimeEditorMode
    let onSave: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTime: Date

    private static let melbourneTimeZone = TimeZone(identifier: "Australia/Melbourne") ?? .current

    init(mode: TimeEditorMode, onSave: @escaping (Int) -> Void) {
        self.mode = mode
        self.onSave = onSave
        _selectedTime = State(initialValue: Self.date(for: mode.initialSeconds))
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Notification Time",
                    selection: $selectedTime,
                    displayedComponents: .hourAndMinute
                )
                .environment(\.timeZone, Self.melbourneTimeZone)
                .datePickerStyle(.wheel)
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(Self.secondsSinceMidnight(for: selectedTime))
                        dismiss()
                    }
                }
            }
        }
    }

    static func date(for seconds: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = melbourneTimeZone
        let startOfDay = calendar.startOfDay(for: Date())
        return calendar.date(
            bySettingHour: seconds / 3600,
            minute: (seconds % 3600) / 60,
            second: 0,
            of: startOfDay
        ) ?? Date()
    }

    private static func secondsSinceMidnight(for date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = melbourneTimeZone
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return (components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60 + (components.second ?? 0)
    }
}
