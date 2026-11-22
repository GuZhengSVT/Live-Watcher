import Foundation

struct LiveSubarea: Codable, Identifiable, Hashable {
    let id: Int
    let name: String

    init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.areaID(forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
    }
}

struct LiveArea: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let children: [LiveSubarea]

    init(id: Int, name: String, children: [LiveSubarea] = []) {
        self.id = id
        self.name = name
        self.children = children
    }

    private enum CodingKeys: String, CodingKey { case id, name, children = "list" }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.areaID(forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
        children = try fields.decodeIfPresent([LiveSubarea].self, forKey: .children) ?? []
    }

    static let defaults = [
        LiveArea(id: 2, name: "网游"), .init(id: 3, name: "手游"), .init(id: 6, name: "单机游戏"),
        .init(id: 1, name: "娱乐"), .init(id: 5, name: "电台"), .init(id: 9, name: "虚拟主播"),
        .init(id: 14, name: "聊天室"), .init(id: 10, name: "生活"), .init(id: 11, name: "知识"),
        .init(id: 13, name: "赛事"), .init(id: 15, name: "互动玩法"), .init(id: 16, name: "购物")
    ]
}

private extension KeyedDecodingContainer {
    // The same endpoint currently returns numeric parent IDs and string child IDs.
    func areaID(forKey key: Key) throws -> Int {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try Int(decode(String.self, forKey: key)) { return value }
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Invalid live area ID")
    }
}

struct Bilibili {
    var session: URLSession = .shared
    private struct Reply<T: Decodable>: Decodable {
        let data: T
        enum CodingKeys: String, CodingKey { case code, message, msg, data }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let code = try c.decode(Int.self, forKey: .code)
            guard code == 0 else {
                let reason = (try? c.decode(String.self, forKey: .message)) ?? (try? c.decode(String.self, forKey: .msg)) ?? "稍后再试"
                throw WatchError.message("B 站返回 \(code) · \(reason)")
            }
            data = try c.decode(T.self, forKey: .data)
        }
    }
    private struct BatchRoom: Decodable {
        let uid: Int64
        let room_id: Int64
        let uname: String?
        let face: String?
        let title: String
        let live_status: Int
        let live_time: Int64
        let area_v2_parent_id: Int
        let area_v2_parent_name: String
        let area_v2_name: String
        let area_v2_id: Int?
        let keyframe: String?
        let cover_from_user: String?

        var room: Room {
            Room(uid: uid, roomID: room_id, name: Bilibili.nonblank(uname) ?? "", title: title,
                 status: live_status, started: live_time, categoryID: area_v2_parent_id,
                 category: area_v2_parent_name, subcategory: area_v2_name, face: Bilibili.nonblank(face),
                 keyframe: live_status == 1 ? Bilibili.nonblank(keyframe) : nil,
                 cover: Bilibili.nonblank(cover_from_user), subcategoryID: area_v2_id.flatMap { $0 > 0 ? $0 : nil })
        }
    }
    private struct Rooms: Decodable {
        let byUID: [Int64: Room]
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let empty = try? c.decode([Int].self), empty.isEmpty { byUID = [:]; return }
            let data = try c.decode([String: BatchRoom].self)
            byUID = data.reduce(into: [:]) { result, entry in
                if Int64(entry.key) == entry.value.uid, entry.value.room_id > 0 {
                    result[entry.value.uid] = entry.value.room
                }
            }
        }
    }
    private struct RoomDetail: Decodable {
        let uid: Int64
        let room_id: Int64
        let live_status: Int
        let area_id: Int?
        let keyframe: String?
        let user_cover: String?
    }
    private struct UserCard: Decodable {
        struct Profile: Decodable {
            let mid: String
            let name: String?
            let face: String?
            let sign: String?
        }
        let card: Profile
    }
    private struct RoomAnchor: Decodable {
        struct Profile: Decodable {
            let uid: Int64
            let uname: String?
            let face: String?
        }
        let info: Profile
    }

    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem] = [],
                                   host: String = "api.live.bilibili.com", timeout: TimeInterval = 15) async throws -> T {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = path
        parts.queryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("LiveWatcher/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://live.bilibili.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WatchError.message("B 站请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
        }
        return try JSONDecoder().decode(Reply<T>.self, from: data).data
    }
    func rooms(_ uids: [Int64]) async throws -> [Int64: Room] {
        guard !uids.isEmpty else { return [:] }
        let data: Rooms = try await get("/room/v1/Room/get_status_info_by_uids",
                                        uids.map { .init(name: "uids[]", value: String($0)) })
        return data.byUID
    }
    func onlineRankCount(for room: Room) async -> Int? {
        guard room.isLive else { return nil }
        struct OnlineRank: Decodable { let count: Int? }
        // The web player's “房间观众” number, not room popularity or lifetime views.
        let rank: OnlineRank? = try? await get("/xlive/general-interface/v1/rank/queryContributionRank", [
            .init(name: "room_id", value: String(room.roomID)), .init(name: "ruid", value: String(room.uid)),
            .init(name: "page", value: "1"), .init(name: "page_size", value: "1"),
            .init(name: "type", value: "online_rank"), .init(name: "switch", value: "contribution_rank"),
            .init(name: "platform", value: "web"), .init(name: "web_location", value: "444.8")
        ], timeout: 4)
        guard let count = rank?.count, count >= 0 else { return nil }
        return count
    }

    private static func nonblank(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    func enrich(_ rooms: [Int64: Room], previous: [Int64: Room] = [:]) async -> [Int64: Room] {
        var result = rooms.mapValues { latest in
            var room = latest
            let old = previous[room.uid]
            room.name = Self.nonblank(room.name) ?? Self.nonblank(old?.name) ?? ""
            room.face = Self.nonblank(room.face) ?? Self.nonblank(old?.face)
            room.signature = Self.nonblank(room.signature) ?? old?.signature ?? room.signature
            // Never carry a cached frame into this refresh. The batch owns detection state.
            room.keyframe = room.isLive ? Self.nonblank(room.keyframe) : nil
            return room
        }
        var pending = result.values.filter { $0.isLive || Self.needsProfile($0) }.makeIterator()
        await withTaskGroup(of: Room.self) { group in
            for _ in 0..<4 {
                guard let room = pending.next() else { break }
                group.addTask { await enrichRoom(room) }
            }
            for await room in group {
                result[room.uid] = room
                if !Task.isCancelled, let next = pending.next() {
                    group.addTask { await enrichRoom(next) }
                }
            }
        }
        return result
    }

    private static func needsProfile(_ room: Room) -> Bool {
        room.name.isEmpty || room.face == nil || room.signature == nil
    }

    private func liveDetail(_ room: Room) async -> RoomDetail? {
        guard room.isLive else { return nil }
        return try? await get("/room/v1/Room/get_info", [.init(name: "room_id", value: String(room.roomID))], timeout: 4)
    }

    private func enrichRoom(_ base: Room) async -> Room {
        var room = base
        async let detail = liveDetail(base)
        async let audience = onlineRankCount(for: base)
        if Self.needsProfile(room) {
            let card: UserCard? = try? await get("/x/web-interface/card", [.init(name: "mid", value: String(room.uid))],
                                                 host: "api.bilibili.com", timeout: 4)
            if let profile = card?.card, Int64(profile.mid) == room.uid {
                if let name = Self.nonblank(profile.name) { room.name = name }
                room.face = Self.nonblank(profile.face) ?? room.face
                // A present but empty sign is a known absence, instead of a lookup failure.
                if let sign = profile.sign, room.signature == nil { room.signature = Self.nonblank(sign) ?? "" }
            }
            if room.name.isEmpty || room.face == nil {
                let anchor: RoomAnchor? = try? await get("/live_user/v1/UserInfo/get_anchor_in_room",
                    [.init(name: "roomid", value: String(room.roomID))], timeout: 4)
                if let profile = anchor?.info, profile.uid == room.uid {
                    if room.name.isEmpty { room.name = Self.nonblank(profile.uname) ?? "" }
                    room.face = room.face ?? Self.nonblank(profile.face)
                }
            }
        }
        if let detail = await detail, detail.uid == room.uid, detail.room_id == room.roomID, detail.live_status == 1 {
            room.keyframe = Self.nonblank(detail.keyframe) ?? room.keyframe
            room.cover = Self.nonblank(detail.user_cover) ?? room.cover
            if room.subcategoryID == nil, let areaID = detail.area_id, areaID > 0 {
                room.subcategoryID = areaID
            }
        }
        room.onlineRankCount = await audience
        return room
    }

    func resolve(_ target: FollowTarget) async throws -> Room {
        let uid: Int64
        switch target {
        case .uid(let id): uid = id
        case .room(let id):
            struct Owner: Decodable { let uid: Int64 }
            let owner: Owner = try await get("/room/v1/Room/room_init", [.init(name: "id", value: String(id))])
            uid = owner.uid
        }
        guard let room = try await rooms([uid])[uid] else {
            throw WatchError.message("找不到此 UP 主的直播间。请检查 UID，或粘贴直播间链接。")
        }
        return await enrich([uid: room])[uid] ?? room
    }
    func areas() async throws -> [LiveArea] { try await get("/room/v1/Area/getList") }
}
