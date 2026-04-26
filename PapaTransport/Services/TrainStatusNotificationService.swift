import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

@MainActor
final class TrainStatusNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TrainStatusNotificationService()

    static let enabledKey = "trainStatusNotificationsEnabled"
    static let selectedWeekdaysKey = "trainStatusNotificationSelectedWeekdays"
    static let timesKey = "trainStatusNotificationTimesSeconds"
    static let timeSecondsKey = "trainStatusNotificationTimeSeconds"
    static let lastSentScheduledDateKey = "trainStatusNotificationLastSentScheduledDate"
    static let defaultWeekdayMask = (2...6).reduce(0) { $0 | (1 << $1) }
    static let defaultTimeSeconds = 7 * 3600

    nonisolated static func encodeTimes(_ times: [Int]) -> String {
        normalizedTimes(times)
            .map(String.init)
            .joined(separator: ",")
    }

    nonisolated static func decodeTimes(_ rawValue: String) -> [Int] {
        normalizedTimes(
            rawValue
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    nonisolated static func normalizedTimes(_ times: [Int]) -> [Int] {
        Array(
            Set(times)
                .filter { (0..<(24 * 3600)).contains($0) }
                .sorted()
        )
    }

    private let taskIdentifier = "org.nando.papatransport.trainStatusRefresh"
    private let notificationIdentifier = "train-status-current"
    private let deliveryGraceInterval: TimeInterval = 2 * 3600
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Melbourne") ?? .current
        return calendar
    }()

    private override init() {
        super.init()
    }

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        registerBackgroundRefresh()
        if isEnabled && !selectedWeekdays.isEmpty && !notificationTimes.isEmpty {
            scheduleNextRefresh()
        }
    }

    func applicationDidEnterBackground() {
        scheduleNextRefresh()
    }

    func notificationSettings() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> UNAuthorizationStatus {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            print("Notification authorization failed: \(error.localizedDescription)")
        }
        return await notificationSettings()
    }

    func settingsDidChange() async {
        if isEnabled, !selectedWeekdays.isEmpty, !notificationTimes.isEmpty {
            scheduleNextRefresh()
        } else {
            cancelNotifications()
        }
    }

    func sendCurrentStatusNow() async throws {
        let status = await notificationSettings()
        guard status == .authorized || status == .provisional else {
            throw TrainStatusNotificationError.notificationsNotAuthorized
        }
        let trainInfo = try await fetchConfiguredTrainInfo()
        try await deliverNotification(for: trainInfo)
        scheduleNextRefresh()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    private var selectedWeekdayMask: Int {
        guard UserDefaults.standard.object(forKey: Self.selectedWeekdaysKey) != nil else {
            return Self.defaultWeekdayMask
        }
        return UserDefaults.standard.integer(forKey: Self.selectedWeekdaysKey)
    }

    private var selectedWeekdays: Set<Int> {
        Set((1...7).filter { selectedWeekdayMask & (1 << $0) != 0 })
    }

    private var notificationTimeSeconds: Int {
        guard UserDefaults.standard.object(forKey: Self.timeSecondsKey) != nil else {
            return Self.defaultTimeSeconds
        }
        return UserDefaults.standard.integer(forKey: Self.timeSecondsKey)
    }

    private var notificationTimes: [Int] {
        let defaults = UserDefaults.standard
        if let rawValue = defaults.string(forKey: Self.timesKey) {
            let decoded = Self.decodeTimes(rawValue)
            if !decoded.isEmpty {
                return decoded
            }
        }
        return [notificationTimeSeconds]
    }

    private func cancelNotifications() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
    }

    private func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            Task { @MainActor in
                await self?.handleAppRefresh(task)
            }
        }
    }

    private func handleAppRefresh(_ task: BGAppRefreshTask) async {
        scheduleNextRefresh()

        let refreshTask = Task {
            do {
                try await sendStatusIfDue()
                task.setTaskCompleted(success: true)
            } catch {
                print("Train status notification refresh failed: \(error.localizedDescription)")
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            refreshTask.cancel()
        }

        await refreshTask.value
    }

    private func sendStatusIfDue() async throws {
        guard isEnabled else {
            print("[TrainNotif] Skipped: notifications not enabled")
            return
        }

        let status = await notificationSettings()
        guard status == .authorized || status == .provisional else {
            print("[TrainNotif] Skipped: not authorized (status=\(status.rawValue))")
            return
        }

        let now = Date()
        guard let scheduledDate = mostRecentScheduledDate(beforeOrEqual: now) else {
            print("[TrainNotif] Skipped: no scheduled date found before \(now)")
            scheduleNextRefresh(after: nextNotificationDate(after: now))
            return
        }

        let elapsed = now.timeIntervalSince(scheduledDate)
        guard elapsed <= deliveryGraceInterval else {
            print("[TrainNotif] Skipped: scheduled date \(scheduledDate) is \(Int(elapsed/60))m ago, outside \(Int(deliveryGraceInterval/60))m grace window")
            scheduleNextRefresh(after: nextNotificationDate(after: now))
            return
        }

        if let lastSent = UserDefaults.standard.object(forKey: Self.lastSentScheduledDateKey) as? Date {
            guard abs(lastSent.timeIntervalSince(scheduledDate)) >= 60 else {
                print("[TrainNotif] Skipped: already sent for scheduled date \(scheduledDate)")
                scheduleNextRefresh(after: nextNotificationDate(after: scheduledDate))
                return
            }
        }

        print("[TrainNotif] Fetching train status for scheduled date \(scheduledDate)")
        let trainInfo = try await fetchConfiguredTrainInfo()
        try await deliverNotification(for: trainInfo)
        print("[TrainNotif] Notification delivered")
        UserDefaults.standard.set(scheduledDate, forKey: Self.lastSentScheduledDateKey)
        scheduleNextRefresh(after: nextNotificationDate(after: scheduledDate))
    }

    private func fetchConfiguredTrainInfo() async throws -> TrainInfo {
        let defaults = UserDefaults.standard
        let lineName = defaults.string(forKey: "trainLineName") ?? ""
        let homeStation = defaults.string(forKey: "homeStation") ?? ""
        let cityStation = defaults.string(forKey: "cityStation") ?? "Flinders Street"

        guard !lineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrainStatusNotificationError.missingTrainLine
        }

        return try await TrainService.shared.fetchTrainInfo(
            lineName: lineName,
            homeStation: homeStation,
            cityStation: cityStation
        )
    }

    private func deliverNotification(for trainInfo: TrainInfo) async throws {
        let content = UNMutableNotificationContent()
        content.title = "\(trainInfo.lineName) line status"
        content.body = notificationBody(for: trainInfo)
        content.sound = .default
        content.threadIdentifier = "train-status"
        content.userInfo = [
            "type": "trainStatus",
            "lineName": trainInfo.lineName
        ]

        let request = UNNotificationRequest(
            identifier: notificationIdentifier,
            content: content,
            trigger: nil
        )

        try await UNUserNotificationCenter.current().add(request)
    }

    private func notificationBody(for trainInfo: TrainInfo) -> String {
        if trainInfo.serviceIsGood {
            return "\(trainInfo.serviceStatusMessage) Updated at \(trainInfo.melbourneTimeAtFetch)."
        }

        if let firstAlert = trainInfo.alerts.first {
            let prefix = firstAlert.additionalTravelMinutes.map { "Allow +\($0) min. " } ?? ""
            return "\(prefix)\(firstAlert.plainText)"
        }

        return trainInfo.serviceStatusMessage
    }

    private func scheduleNextRefresh(after requestedDate: Date? = nil) {
        guard isEnabled, !selectedWeekdays.isEmpty, !notificationTimes.isEmpty else {
            cancelNotifications()
            return
        }

        let nextDate = requestedDate ?? nextNotificationDate(after: Date())
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = nextDate

        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Failed to schedule train status refresh: \(error.localizedDescription)")
        }
    }

    private func nextNotificationDate(after date: Date) -> Date {
        let weekdays = selectedWeekdays
        let times = notificationTimes
        guard !weekdays.isEmpty, !times.isEmpty else {
            return date.addingTimeInterval(24 * 3600)
        }

        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: day)
            guard weekdays.contains(weekday) else { continue }

            for time in times {
                let candidate = dateSetting(secondsSinceMidnight: time, on: day)
                if candidate > date {
                    return candidate
                }
            }
        }

        return date.addingTimeInterval(24 * 3600)
    }

    private func mostRecentScheduledDate(beforeOrEqual date: Date) -> Date? {
        let weekdays = selectedWeekdays
        let times = notificationTimes.reversed()
        guard !weekdays.isEmpty, !times.isEmpty else { return nil }

        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: date)) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: day)
            guard weekdays.contains(weekday) else { continue }

            for time in times {
                let candidate = dateSetting(secondsSinceMidnight: time, on: day)
                if candidate <= date {
                    return candidate
                }
            }
        }

        return nil
    }

    private func dateSetting(secondsSinceMidnight: Int, on date: Date) -> Date {
        let hour = secondsSinceMidnight / 3600
        let minute = (secondsSinceMidnight % 3600) / 60
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: startOfDay) ?? date
    }
}

enum TrainStatusNotificationError: LocalizedError {
    case missingTrainLine
    case notificationsNotAuthorized

    var errorDescription: String? {
        switch self {
        case .missingTrainLine:
            return "Choose a Victorian train line before sending train status notifications."
        case .notificationsNotAuthorized:
            return "Notifications are not allowed for PapaTransport."
        }
    }
}
