import AppIntents
import ImageIO
import SwiftUI
import WidgetKit

struct StationEntry: TimelineEntry {
    let date: Date
    let page: WidgetLivePage
    var error: String?
    var avatars: [Int64: CGImage] = [:]
    var onlineRankCounts: [Int64: Int] = [:]
    static let example: StationEntry = {
        let room = Room(uid: 1, roomID: 1, name: "观测站示例", title: "和大家一起听深夜电台",
                        status: 1, started: 1, categoryID: 5, category: "电台", subcategory: "音乐电台", face: nil, onlineRankCount: 128)
        return .init(date: Date(), page: WidgetLivePage(live: [Channel(room: room, checked: Date())],
                                                       pageSize: 1, requestedIndex: 0))
    }()
}

private enum WidgetPageSize: String, AppEnum {
    case small, medium, large

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "小组件尺寸"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .small: "小型", .medium: "中型", .large: "大型"
    ]

    var channelLimit: Int {
        switch self {
        case .small: return 1
        case .medium: return 2
        case .large: return 5
        }
    }

    var savedPage: Int {
        guard let url = try? pageLocation(), let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return Int(text) ?? 0
    }

    func savePage(_ index: Int) throws {
        try Data(String(index).utf8).write(to: pageLocation(), options: .atomic)
    }

    private func pageLocation() throws -> URL {
        try StationStore.location().deletingLastPathComponent().appendingPathComponent("widget-page-\(rawValue).txt")
    }
}

private extension WidgetFamily {
    var pageSize: WidgetPageSize {
        switch self {
        case .systemSmall: return .small
        case .systemLarge: return .large
        default: return .medium
        }
    }
}

private struct ChangeLiveWidgetPage: AppIntent {
    static let title: LocalizedStringResource = "切换直播小组件页码"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "小组件尺寸") var size: WidgetPageSize
    @Parameter(title: "页码") var page: Int

    init() {}
    init(size: WidgetPageSize, page: Int) {
        self.size = size
        self.page = page
    }

    func perform() async throws -> some IntentResult {
        // Save before returning: WidgetKit reloads the timeline after the intent completes.
        try size.savePage(page)
        return .result()
    }
}

struct StationProvider: TimelineProvider {
    func placeholder(in context: Context) -> StationEntry { .example }
    func getSnapshot(in context: Context, completion: @escaping (StationEntry) -> Void) {
        if context.isPreview { completion(.example); return }
        Task { completion(await entry(for: context.family, refresh: false)) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StationEntry>) -> Void) {
        Task {
            let entry = await entry(for: context.family, refresh: true)
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }

    private func entry(for family: WidgetFamily, refresh: Bool) async -> StationEntry {
        let size = family.pageSize
        do {
            var station = try StationStore.load()
            if refresh { await Self.refresh(&station) }
            let page = WidgetLivePage(live: station.live, pageSize: size.channelLimit, requestedIndex: size.savedPage)
            let assets = refresh ? await Self.assets(for: page.channels) : (avatars: [:], counts: [:])
            return .init(date: Date(), page: page, avatars: assets.avatars, onlineRankCounts: assets.counts)
        } catch {
            let page = WidgetLivePage(live: [], pageSize: size.channelLimit, requestedIndex: 0)
            return .init(date: Date(), page: page, error: "暂时无法读取关注列表")
        }
    }

    private static func refresh(_ station: inout Station) async {
        let now = Date()
        let stale = station.channels.filter {
            $0.unavailable || now.timeIntervalSince($0.checked) > Double(station.preferences.interval) + 5
        }.map(\.id)
        // WidgetKit can wake the extension independently of the menu bar process.
        // Keep these observations local so it cannot consume the app's notification transitions.
        for start in stride(from: 0, to: stale.count, by: 40) {
            let batch = Array(stale[start..<min(start + 40, stale.count)])
            let rooms = (try? await Bilibili().rooms(batch)) ?? [:]
            _ = station.merge(rooms, requested: Set(batch), since: now, at: Date())
        }
    }

    private static func assets(for channels: [Channel]) async -> (avatars: [Int64: CGImage], counts: [Int64: Int]) {
        let api = Bilibili()
        // Reuse the main app's observation, requesting a missing count only for the current page.
        return await withTaskGroup(of: (Int64, CGImage?, Int?).self) { group in
            for channel in channels {
                let room = channel.room
                group.addTask {
                    async let image = Self.avatar(from: room.face)
                    async let count = room.onlineRankCount == nil ? api.onlineRankCount(for: room) : nil
                    return await (room.id, image, count)
                }
            }
            var avatars: [Int64: CGImage] = [:]
            var counts: [Int64: Int] = [:]
            for await (uid, image, count) in group {
                avatars[uid] = image
                counts[uid] = count
            }
            return (avatars, counts)
        }
    }

    private static func avatar(from face: String?) async -> CGImage? {
        guard let face, var parts = URLComponents(string: face), parts.host != nil,
              parts.scheme == "http" || parts.scheme == "https" else { return nil }
        parts.scheme = "https"
        guard let url = parts.url,
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 96
        ] as CFDictionary)
    }
}

struct StationWidgetView: View {
    let entry: StationEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    private var small: Bool { family == .systemSmall }
    private var large: Bool { family == .systemLarge }
    private var dark: Bool { colorScheme == .dark }
    private var surface: Color { dark ? .black : .white }
    private var ink: Color { dark ? Color(red: 0.85, green: 0.95, blue: 0.81) : .black }
    private var muted: Color { ink.opacity(0.65) }
    private var signal: Color { dark ? ink : Color(red: 0.21, green: 0.41, blue: 0.25) }

    var body: some View {
        let page = entry.page
        VStack(alignment: .leading, spacing: large ? 11 : small ? 4 : 6) {
            HStack(spacing: 6) {
                Aster().fill(ink).frame(width: small ? 15 : 19, height: small ? 15 : 19)
                Text("Live Watcher").font(.custom("Georgia-BoldItalic", size: small ? 17 : 21))
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                if !small {
                    Text("\(page.liveCount) 场直播").font(.system(size: 13, weight: .semibold)).foregroundStyle(muted)
                    if page.pageCount > 1 { pager }
                }
            }
            Rectangle().fill(ink.opacity(0.18)).frame(height: 1)
            if let first = page.channels.first {
                if small {
                    compactChannel(first)
                } else {
                    ForEach(page.channels) { channel in
                        Link(destination: channel.room.widgetURL) { channelRow(channel) }
                    }
                }
            } else {
                Spacer(minLength: 0)
                Text(entry.error ?? "暂无正在直播的 UP 主").font(.system(size: 16, weight: .bold))
                Text("点按打开直播观测站").font(.system(size: 12)).foregroundStyle(muted)
            }
            if small && page.pageCount > 1 {
                pager.frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(ink)
        .containerBackground(for: .widget) { surface }
        .widgetURL(small ? page.channels.first?.room.widgetURL : nil)
    }

    private var pager: some View {
        HStack(spacing: 2) {
            pageButton(previous: true)
            Text("\(entry.page.index + 1)/\(entry.page.pageCount)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(muted)
                .accessibilityLabel("第 \(entry.page.index + 1) 页，共 \(entry.page.pageCount) 页")
            pageButton(previous: false)
        }
        .fixedSize()
    }

    private func pageButton(previous: Bool) -> some View {
        let target = entry.page.index + (previous ? -1 : 1)
        let enabled = (0..<entry.page.pageCount).contains(target)
        return Button(intent: ChangeLiveWidgetPage(size: family.pageSize, page: target)) {
            Image(systemName: previous ? "chevron.backward" : "chevron.forward")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? ink : ink.opacity(0.3))
        .disabled(!enabled)
        .accessibilityLabel(previous ? Text("上一页") : Text("下一页"))
    }

    @ViewBuilder
    private func compactChannel(_ channel: Channel) -> some View {
        HStack(spacing: 7) {
            avatar(channel, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.room.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                countLabel(channel).font(.system(size: 12, weight: .medium)).foregroundStyle(signal)
                    .minimumScaleFactor(0.75)
            }
        }
        Text(channel.room.displayTitle).font(.system(size: 16, weight: .bold)).lineLimit(2)
    }

    private func channelRow(_ channel: Channel) -> some View {
        HStack(spacing: 10) {
            avatar(channel, size: large ? 42 : 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.room.displayTitle)
                    .font(.system(size: large ? 17 : 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.88)
                HStack(spacing: 6) {
                    Text(channel.room.displayName).lineLimit(1)
                    Spacer(minLength: 0)
                    countLabel(channel).fixedSize(horizontal: true, vertical: false)
                }.font(.system(size: large ? 13 : 12)).foregroundStyle(muted)
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
        }
        .contentShape(Rectangle())
    }

    private func countLabel(_ channel: Channel) -> some View {
        Text(Room.onlineRankLabel(channel.room.onlineRankCount ?? entry.onlineRankCounts[channel.id]))
            .monospacedDigit().lineLimit(1)
            .accessibilityHint("B 站公开在线榜人数")
    }

    private func avatar(_ channel: Channel, size: CGFloat) -> some View {
        Group {
            if let photo = entry.avatars[channel.id] {
                Image(decorative: photo, scale: 2).resizable().scaledToFill()
            } else {
                Text(String(channel.room.displayName.prefix(1))).font(.system(size: size * 0.44, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size, height: size)
        .background(ink.opacity(0.10))
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            Circle().fill(signal).frame(width: 8, height: 8)
                .padding(2).background(surface, in: Circle())
        }
        .accessibilityHidden(true)
    }
}

@main
struct LiveWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LiveWatcherStation", provider: StationProvider()) { entry in StationWidgetView(entry: entry) }
            .configurationDisplayName("直播观测站 · Live Watcher")
            .description("查看关注的 UP 主正在进行的直播，可翻页浏览。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
