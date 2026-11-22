import Foundation

@main enum BilibiliSmoke {
    static func main() async throws {
        let api = Bilibili()
        let viaShort = try await api.resolve(.room(6))
        let viaUID = try await api.resolve(.uid(viaShort.uid))
        precondition(viaUID.roomID == viaShort.roomID)
        let batch = try await api.rooms([viaUID.uid, 672328094])
        precondition(batch[viaUID.uid] != nil)
        let areas = try await api.areas()
        precondition(areas.contains(where: { $0.id == viaUID.categoryID }))
        guard let virtual = areas.first(where: { $0.id == 9 }), virtual.children.count > 1 else {
            throw WatchError.message("虚拟主播分区没有返回可独立设置的二级分区。")
        }
        print("\(virtual.name)二级分区：\(virtual.children.map { $0.name }.joined(separator: "、"))")
        let enriched = await api.enrich(batch)
        let live = enriched.values.filter(\.isLive)
        if !live.isEmpty && !live.contains(where: { $0.onlineRankCount != nil }) {
            throw WatchError.message("在线榜暂未返回直播间的房间观众人数。")
        }
        for room in enriched.values.sorted(by: { $0.uid < $1.uid }) {
            let artwork = room.keyframe != nil ? "画面帧" : (room.cover != nil ? "房间封面" : "无预览")
            print("\(room.displayName) · \(room.statusLabel) · \(room.category) / \(room.subcategory) · 个签：\(room.signature?.isEmpty == false ? "有" : "无") · \(artwork) · \(room.isLive ? Room.onlineRankLabel(room.onlineRankCount) : "非直播") · \(room.webURL)")
        }
        print("Live category count: \(areas.count). Room short ID and UID resolve consistently.")
    }
}
