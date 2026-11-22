import CalendarCore
import Combine
import Foundation

struct ScheduleDocument {
    let text: String
    let calendar: ICalendarImport
    let recurrenceZones: [String: TimeZone]

    init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard trimmed.prefix(15).uppercased() == "BEGIN:VCALENDAR",
              trimmed.suffix(13).uppercased() == "END:VCALENDAR" else {
            throw WatchError.message("这个链接没有返回完整的 ICS 日历，请检查订阅地址。")
        }
        self.text = trimmed
        calendar = try ICalendar.read(trimmed, calendar: ScheduleWeek.calendar)
        recurrenceZones = calendar.events.contains { $0.recurrence != nil } ? Self.recurrenceZones(in: trimmed) : [:]
    }

    // CalendarCore returns absolute starts. Keep the series' wall-clock zone for expansion across DST.
    private static func recurrenceZones(in text: String) -> [String: TimeZone] {
        let unfolded = text.replacingOccurrences(of: #"\r?\n[ \t]"#, with: "", options: .regularExpression)
        var result: [String: TimeZone] = [:]
        var depth = 0
        var uid = ""
        var zone: TimeZone?
        var repeats = false
        unfolded.enumerateLines { line, _ in
            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return }
            let header = fields[0].split(separator: ";")
            let value = String(fields[1])
            switch header.first?.uppercased() {
            case "BEGIN" where value.uppercased() == "VEVENT":
                depth = 1
                uid = ""
                zone = nil
                repeats = false
            case "BEGIN" where depth > 0: depth += 1
            case "END" where depth > 0:
                if depth == 1, repeats, !uid.isEmpty { result[uid] = zone }
                depth -= 1
            case "UID" where depth == 1: uid = value
            case "RRULE" where depth == 1: repeats = true
            case "DTSTART" where depth == 1:
                if value.hasSuffix("Z") { zone = TimeZone(secondsFromGMT: 0) }
                else if let parameter = header.dropFirst().first(where: { $0.uppercased().hasPrefix("TZID=") }) {
                    zone = TimeZone(identifier: String(parameter.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                }
            default: break
            }
        }
        return result
    }

    static func url(from input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text),
              ["https", "webcal"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty else {
            throw WatchError.message("请输入 https:// 或 webcal:// 开头的 ICS 订阅链接。")
        }
        parts.scheme = "https"
        parts.host = host.lowercased()
        parts.fragment = nil
        guard let url = parts.url else { throw WatchError.message("无法识别订阅链接。") }
        return url
    }

    static func fetch(_ url: URL) async throws -> Self {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("text/calendar, */*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WatchError.message("日历服务器未能返回订阅内容。")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw WatchError.message("订阅内容无法按 UTF-8 读取。")
        }
        return try Self(text)
    }
}

struct ScheduleSubscription: Identifiable {
    struct Record: Codable {
        var id: UUID
        var url: URL
        var channelID: Int64?
        var updated: Date
        var text: String
    }
    let record: Record
    let document: ScheduleDocument
    var id: UUID { record.id }
    var timelineSourceID: String {
        record.channelID.map { "channel:\($0)" } ?? "subscription:\(id.uuidString)"
    }
    var name: String {
        if let name = document.calendar.name, !name.isEmpty { return name }
        return record.url.host ?? "直播日程"
    }

    func displayName(channels: [Channel]) -> String {
        channels.first { $0.id == record.channelID }?.room.displayName ?? name
    }
}

@MainActor
final class ScheduleStore: ObservableObject {
    @Published private(set) var subscriptions: [ScheduleSubscription] = []
    @Published private(set) var refreshing: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var storageError: String?

    @Published private var hiddenTimelineSources: Set<String>
    private let defaults: UserDefaults
    private static let hiddenSourcesKey = "timeline.hiddenSources"
    private let file: URL
    private let fetch: (URL) async throws -> ScheduleDocument
    private static let interval: TimeInterval = 30 * 60
    private var started = false
    private var timer: Timer?

    init(file: URL = URL.applicationSupportDirectory.appending(path: "Live Watcher/schedules.json"),
         defaults: UserDefaults = .standard,
         fetch: @escaping (URL) async throws -> ScheduleDocument = ScheduleDocument.fetch) {
        self.defaults = defaults
        hiddenTimelineSources = Set(defaults.stringArray(forKey: Self.hiddenSourcesKey) ?? [])
        self.file = file
        self.fetch = fetch
    }

    func showsOnTimeline(_ feed: ScheduleSubscription) -> Bool {
        !hiddenTimelineSources.contains(feed.timelineSourceID)
    }

    func setTimelineVisible(_ visible: Bool, for feed: ScheduleSubscription) {
        if visible { hiddenTimelineSources.remove(feed.timelineSourceID) }
        else { hiddenTimelineSources.insert(feed.timelineSourceID) }
        defaults.set(hiddenTimelineSources.sorted(), forKey: Self.hiddenSourcesKey)
    }

    func start() {
        guard !started else { return }
        started = true
        do {
            let records = try JSONDecoder().decode([ScheduleSubscription.Record].self, from: Data(contentsOf: file))
            subscriptions = try records.map { ScheduleSubscription(record: $0, document: try ScheduleDocument($0.text)) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First launch.
        } catch {
            storageError = "读取订阅失败 · " + error.localizedDescription
            return
        }
        Task { await refresh(staleOnly: true) }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func commit(_ next: [ScheduleSubscription]) throws {
        if let storageError { throw WatchError.message(storageError) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next.map(\.record)).write(to: file, options: .atomic)
        subscriptions = next
    }

    func save(input: String, channelID: Int64?, editing id: UUID?) async throws {
        let url = try ScheduleDocument.url(from: input)
        func validate() throws {
            if let id, !subscriptions.contains(where: { $0.id == id }) { throw WatchError.message("这份订阅已被移除。") }
            if subscriptions.contains(where: { $0.record.url == url && $0.id != id }) {
                throw WatchError.message("此链接已经订阅，可在「管理订阅」中更改关联的 UP 主。")
            }
        }
        try validate()
        if let index = subscriptions.firstIndex(where: { $0.id == id && $0.record.url == url }) {
            var next = subscriptions
            var record = next[index].record
            record.channelID = channelID
            next[index] = ScheduleSubscription(record: record, document: next[index].document)
            try commit(next)
            return
        }
        let document = try await fetch(url)
        try validate()
        let record = ScheduleSubscription.Record(id: id ?? UUID(), url: url, channelID: channelID,
                                                 updated: Date(), text: document.text)
        let item = ScheduleSubscription(record: record, document: document)
        var next = subscriptions
        if let index = next.firstIndex(where: { $0.id == id }) { next[index] = item }
        else { next.append(item) }
        try commit(next)
        errors[record.id] = nil
    }

    func remove(_ id: UUID) throws {
        try commit(subscriptions.filter { $0.id != id })
        errors[id] = nil
    }

    func refresh(channelID: Int64? = nil, staleOnly: Bool = false) async {
        for feed in subscriptions where channelID == nil || feed.record.channelID == channelID {
            guard let current = subscriptions.first(where: { $0.id == feed.id }),
                  !staleOnly || Date().timeIntervalSince(current.record.updated) >= Self.interval,
                  refreshing.insert(feed.id).inserted else { continue }
            defer { refreshing.remove(feed.id) }
            do {
                let doc = try await fetch(current.record.url)
                guard let index = subscriptions.firstIndex(where: { $0.id == feed.id && $0.record.updated == current.record.updated }) else { continue }
                var record = subscriptions[index].record
                record.text = doc.text
                record.updated = Date()
                var next = subscriptions
                next[index] = ScheduleSubscription(record: record, document: doc)
                try commit(next)
                errors[feed.id] = nil
            } catch {
                if subscriptions.contains(where: { $0.id == feed.id && $0.record.updated == current.record.updated }) {
                    errors[feed.id] = error.localizedDescription
                }
            }
        }
    }
}

enum ScheduleWeek {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        return calendar
    }

    static func interval(containing date: Date, calendar: Calendar = calendar) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date)!
    }

    struct Entry: Identifiable {
        struct ID: Hashable {
            let source: UUID
            let event: String
            let start: Date
        }
        let id: ID
        let source: ScheduleSubscription
        let occurrence: Occurrence<ICalendarEvent>

        func hasEnded(at now: Date) -> Bool {
            if occurrence.start == occurrence.end { return occurrence.start < now }
            return occurrence.end <= now
        }

        func isOngoing(at now: Date) -> Bool {
            occurrence.start <= now && now < occurrence.end
        }
    }

    static func entries(_ feeds: [ScheduleSubscription], in week: DateInterval, calendar: Calendar = calendar) -> [Entry] {
        feeds.flatMap { feed in
            let document = feed.document
            let groups = Dictionary(grouping: document.calendar.events) { document.recurrenceZones[$0.id] ?? calendar.timeZone }
            return groups.flatMap { zone, events in
                var eventCalendar = calendar
                eventCalendar.timeZone = zone
                return Timetable.expand(events, in: week, calendar: eventCalendar).map {
                    Entry(id: Entry.ID(source: feed.id, event: $0.event.id, start: $0.start), source: feed, occurrence: $0)
                }
            }
        }.sorted {
            if $0.occurrence.start != $1.occurrence.start { return $0.occurrence.start < $1.occurrence.start }
            if $0.occurrence.event.title != $1.occurrence.event.title { return $0.occurrence.event.title < $1.occurrence.event.title }
            return $0.id.source.uuidString < $1.id.source.uuidString
        }
    }
}
