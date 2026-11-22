import AppKit
import Combine
import UserNotifications
import WidgetKit

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var station = Station()
    @Published private(set) var refreshing = false
    @Published private(set) var areas = LiveArea.defaults
    @Published private(set) var authorization = UNAuthorizationStatus.notDetermined
    @Published var issue: String?
    private let api = Bilibili()
    private var timer: Timer?
    private var started = false
    private var readable = false

    func start() {
        guard !started else { return }
        started = true
        do { station = try StationStore.load(); readable = true }
        catch { issue = error.localizedDescription }
        applyAppearance()
        schedule()
        Task { await refresh(); await checkAuthorization() }
    }

    private func applyAppearance() {
        NSApp.appearance = switch station.preferences.appearance.mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    private func schedule() {
        timer?.invalidate()
        guard !station.channels.isEmpty else { return }
        let timer = Timer(timeInterval: TimeInterval(station.preferences.interval), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer.tolerance = min(2, timer.timeInterval / 10)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @discardableResult
    private func commit(_ next: Station, reloadWidget: Bool = false) -> Bool {
        guard readable else { issue = "无法读取现有关注列表，请重新打开应用。"; return false }
        do {
            try StationStore.save(next)
            let reschedule = next.preferences.interval != station.preferences.interval || next.channels.isEmpty != station.channels.isEmpty
            let appearanceChanged = next.preferences.appearance.mode != station.preferences.appearance.mode
            station = next
            if appearanceChanged { applyAppearance() }
            if reschedule { schedule() }
            if reloadWidget { WidgetCenter.shared.reloadTimelines(ofKind: "LiveWatcherStation") }
            return true
        } catch { issue = error.localizedDescription; return false }
    }

    func follow(_ input: String) async throws {
        let room = try await api.resolve(FollowTarget(input))
        guard !station.channels.contains(where: { $0.id == room.id }) else {
            throw WatchError.message("已关注「\(room.displayName)」。")
        }
        var next = station
        next.channels.append(Channel(room: room, checked: Date()))
        next.lastCheck = Date()
        guard commit(next, reloadWidget: true) else { throw WatchError.message(issue ?? "保存失败。") }
        if next.preferences.alerts { Task { await requestAuthorizationIfNeeded() } }
    }

    func remove(_ uid: Int64) {
        var next = station
        next.channels.removeAll { $0.id == uid }
        commit(next, reloadWidget: true)
    }

    func toggleAlerts(for uid: Int64) {
        guard let index = station.channels.firstIndex(where: { $0.id == uid }) else { return }
        var next = station
        next.channels[index].alerts.toggle()
        commit(next)
    }

    func setCategoryRules(_ rules: CategoryRules?, for uid: Int64) {
        guard let index = station.channels.firstIndex(where: { $0.id == uid }),
              station.channels[index].categoryRules != rules else { return }
        var next = station
        next.channels[index].categoryRules = rules
        commit(next)
    }

    func configure(_ change: (inout Preferences) -> Void) {
        var next = station
        change(&next.preferences)
        guard next.preferences != station.preferences else { return }
        let enabling = !station.preferences.alerts && next.preferences.alerts
        if commit(next), enabling { Task { await requestAuthorizationIfNeeded() } }
    }

    func refresh() async {
        guard !refreshing, !station.channels.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        let uids = station.channels.map(\.id)
        let since = Date()
        var failures: [String] = []
        var changed = false
        for start in stride(from: 0, to: uids.count, by: 40) {
            let batch = Array(uids[start..<min(start + 40, uids.count)])
            let rooms: [Int64: Room]
            do {
                let latest = try await api.rooms(batch)
                let previous = Dictionary(station.channels.lazy
                    .filter { latest[$0.id] != nil && $0.checked <= since }
                    .map { ($0.id, $0.room) }, uniquingKeysWith: { first, _ in first })
                rooms = await api.enrich(latest, previous: previous)
            } catch { rooms = [:]; failures.append(error.localizedDescription) }
            var next = station
            let events = next.merge(rooms, requested: Set(batch), since: since, at: Date())
            let displayChanged = zip(station.channels, next.channels).contains {
                widgetContent($0.room) != widgetContent($1.room) || $0.unavailable != $1.unavailable
            }
            guard commit(next) else { break }
            changed = changed || displayChanged
            for room in events {
                do { try await LiveNotifications.post(room, sound: next.preferences.sound) }
                catch { failures.append("通知发送失败 · " + error.localizedDescription) }
            }
        }
        if changed { WidgetCenter.shared.reloadTimelines(ofKind: "LiveWatcherStation") }
        if let failure = failures.first { issue = failure }
        else if readable && station.channels.contains(where: \.unavailable) { issue = "部分直播间暂未返回状态，将在下次检测时重试。" }
        else if readable { issue = nil }
    }

    // Ignore artwork and profiles, but keep the live count so count-only changes update the widget.
    private func widgetContent(_ room: Room) -> Room {
        var visible = room
        visible.signature = nil
        visible.keyframe = nil
        visible.cover = nil
        visible.subcategoryID = nil
        return visible
    }

    func loadSettings() async {
        await checkAuthorization()
        if let current = try? await api.areas(), !current.isEmpty { areas = current }
    }

    func checkAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorizationIfNeeded() async {
        await checkAuthorization()
        if authorization == .notDetermined {
            do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
            catch { issue = error.localizedDescription }
            await checkAuthorization()
        }
    }
}

enum LiveNotifications {
    static func post(_ room: Room, sound: Bool) async throws {
        let content = UNMutableNotificationContent()
        content.title = room.displayName + " 开播了"
        content.body = room.displayTitle
        content.subtitle = [room.category, room.subcategory].filter { !$0.isEmpty }.joined(separator: " / ")
        content.sound = sound ? .default : nil
        content.userInfo = ["room": room.roomID]
        let session = room.started > 0 ? String(room.started) : UUID().uuidString
        let request = UNNotificationRequest(identifier: "live.\(room.uid).\(session)", content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}

final class NotificationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = response.notification.request.content.userInfo["room"] as? NSNumber, id.int64Value > 0,
              let url = URL(string: "https://live.bilibili.com/\(id.int64Value)") else { return }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }
}
