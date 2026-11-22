import Foundation

struct Room: Codable, Equatable, Identifiable {
    let uid: Int64
    let roomID: Int64
    var name: String
    let title: String
    let status: Int
    let started: Int64
    let categoryID: Int
    let category: String
    let subcategory: String
    var face: String?
    var signature: String? = nil
    var keyframe: String? = nil
    var cover: String? = nil
    var subcategoryID: Int? = nil
    var onlineRankCount: Int? = nil

    var id: Int64 { uid }
    var isLive: Bool { status == 1 }
    var statusLabel: String {
        switch status {
        case 0: return "未开播"
        case 1: return "直播中"
        case 2: return "轮播中"
        default: return "状态未知"
        }
    }
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "UID \(uid)" : trimmed
    }
    var displayTitle: String { title.isEmpty ? displayName + "的直播间" : title }
    static func onlineRankLabel(_ count: Int?) -> String {
        "同接 \(count?.formatted() ?? "—")"
    }
    var webURL: URL { URL(string: "https://live.bilibili.com/\(roomID)")! }
    var dynamicURL: URL { URL(string: "https://space.bilibili.com/\(uid)/dynamic")! }
    var widgetURL: URL { URL(string: "livewatcher://room/\(roomID)")! }

    enum CodingKeys: String, CodingKey {
        case uid, title, face, signature, keyframe, cover, onlineRankCount
        case roomID = "room_id", name = "uname", status = "live_status", started = "live_time"
        case categoryID = "area_v2_parent_id", category = "area_v2_parent_name", subcategory = "area_v2_name"
        case subcategoryID = "area_v2_id"
    }
}

struct Channel: Codable, Equatable, Identifiable {
    var room: Room
    var alerts = true
    var checked: Date
    var unavailable = false
    var categoryRules: CategoryRules? = nil
    var id: Int64 { room.uid }

    mutating func update(with latest: Room, at date: Date, preferences: Preferences) -> Bool {
        let newSession = latest.isLive && (!room.isLive ||
            (latest.started > 0 && room.started > 0 && latest.started != room.started))
        var merged = latest
        func nonblank(_ value: String?) -> Bool {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        if !nonblank(latest.name) { merged.name = room.name }
        if !nonblank(latest.face) { merged.face = room.face }
        if !nonblank(latest.signature) {
            // An empty signature can mean the profile is known to have none, rather than unqueried.
            merged.signature = room.signature ?? latest.signature
        }
        if !latest.isLive || !nonblank(latest.keyframe) { merged.keyframe = nil }
        if !latest.isLive { merged.onlineRankCount = nil }
        room = merged
        checked = date
        unavailable = false
        return newSession && alerts &&
            preferences.allows(latest.categoryID, latest.subcategoryID, overriding: categoryRules)
    }
}

struct CategoryRules: Codable, Equatable {
    var defaultAllowed = true
    var groups: [Int: Bool] = [:]
    var subgroups: [Int: [Int: Bool]] = [:]

    func allows(_ group: Int, _ subgroup: Int? = nil) -> Bool {
        if let subgroup, let allowed = subgroups[group]?[subgroup] { return allowed }
        return groups[group] ?? defaultAllowed
    }

    mutating func setGroup(_ id: Int, allowed: Bool) {
        groups[id] = allowed
        subgroups[id] = nil
    }

    mutating func setSubgroup(_ id: Int, in group: Int, allowed: Bool) {
        if allowed == allows(group) {
            subgroups[group]?[id] = nil
            if subgroups[group]?.isEmpty == true { subgroups[group] = nil }
        } else {
            subgroups[group, default: [:]][id] = allowed
        }
    }
}

enum AppearanceMode: String, Codable, CaseIterable { case system, light, dark }
enum AppearancePalette: String, Codable, CaseIterable { case mint, white, black, claude, winter }

struct Appearance: Codable, Equatable {
    var fontSize: Double = 14
    var mode: AppearanceMode = .system
    var palette: AppearancePalette = .mint
}

struct Preferences: Codable, Equatable {
    var interval = 60
    var alerts = true
    var sound = true
    var categories: Set<Int>? // Legacy whitelist; edits use effectiveRules.
    private var categoryRules: CategoryRules?
    var appearance = Appearance()
    static let intervalRange = 15...3600

    var effectiveRules: CategoryRules {
        get {
            if let categoryRules { return categoryRules }
            guard let categories else { return CategoryRules() }
            return CategoryRules(defaultAllowed: false, groups: Dictionary(uniqueKeysWithValues: categories.map { ($0, true) }))
        }
        set {
            categoryRules = newValue
            categories = nil
        }
    }

    func allows(_ group: Int, _ subgroup: Int? = nil, overriding rules: CategoryRules? = nil) -> Bool {
        alerts && (rules ?? effectiveRules).allows(group, subgroup)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interval = try container.decode(Int.self, forKey: .interval)
        alerts = try container.decode(Bool.self, forKey: .alerts)
        sound = try container.decode(Bool.self, forKey: .sound)
        categories = try container.decodeIfPresent(Set<Int>.self, forKey: .categories)
        categoryRules = try container.decodeIfPresent(CategoryRules.self, forKey: .categoryRules)
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? Appearance()
    }
}

struct Station: Codable, Equatable {
    var channels: [Channel] = []
    var preferences = Preferences()
    var lastCheck: Date?

    var ordered: [Channel] {
        channels.sorted { a, b in
            let rank: (Channel) -> Int = { $0.unavailable ? 2 : ($0.room.isLive ? 0 : 1) }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.room.isLive && b.room.isLive && a.room.started != b.room.started {
                return a.room.started > b.room.started
            }
            return a.room.displayName.localizedStandardCompare(b.room.displayName) == .orderedAscending
        }
    }
    var live: [Channel] { ordered.filter { !$0.unavailable && $0.room.isLive } }

    // Apply only the requested batch. A removed/re-added channel may have a newer observation.
    mutating func merge(_ rooms: [Int64: Room], requested: Set<Int64>, since: Date, at date: Date) -> [Room] {
        var events: [Room] = []
        for i in channels.indices where requested.contains(channels[i].id) && channels[i].checked <= since {
            guard let room = rooms[channels[i].id] else {
                channels[i].unavailable = true
                continue
            }
            if channels[i].update(with: room, at: date, preferences: preferences) {
                events.append(channels[i].room)
            }
        }
        lastCheck = date
        return events
    }
}

enum StationStore {
    static func location() throws -> URL {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "WatcherGroup") as? String,
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { throw WatchError.message("无法打开小组件共享容器。请检查应用签名。") }
        return directory.appendingPathComponent("station.json")
    }
    static func load() throws -> Station {
        let url = try location()
        do { return try JSONDecoder().decode(Station.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Station() }
    }
    static func save(_ state: Station) throws {
        try JSONEncoder().encode(state).write(to: location(), options: .atomic)
    }
}

enum FollowTarget: Equatable {
    case uid(Int64)
    case room(Int64)

    init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        func number(_ text: String) -> Int64? {
            guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int64(text), value > 0 else { return nil }
            return value
        }
        if let id = number(text) { self = .uid(id); return }
        let url = URLComponents(string: text.contains("://") ? text : "https://" + text)
        if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let first = url.path.split(separator: "/").first, let id = number(String(first)) {
            switch url.host?.lowercased() {
            case "space.bilibili.com": self = .uid(id); return
            case "live.bilibili.com": self = .room(id); return
            default: break
            }
        }
        throw WatchError.message("请输入有效的 UID、B 站个人空间链接或直播间链接。")
    }
}

enum RoomRoute {
    static func destination(for url: URL) -> URL? {
        guard url.scheme == "livewatcher", url.host == "room",
              let id = Int64(url.lastPathComponent), id > 0, url.path == "/\(id)" else { return nil }
        return URL(string: "https://live.bilibili.com/\(id)")
    }
}
enum WatchError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case let .message(text): return text }
    }
}

struct WidgetLivePage {
    let channels: [Channel]
    let liveCount: Int
    let pageCount: Int
    let index: Int

    init(live: [Channel], pageSize: Int, requestedIndex: Int) {
        liveCount = live.count
        pageCount = live.isEmpty ? 0 : (live.count - 1) / pageSize + 1
        index = min(max(0, requestedIndex), max(0, pageCount - 1))
        channels = Array(live.dropFirst(index * pageSize).prefix(pageSize))
    }
}
