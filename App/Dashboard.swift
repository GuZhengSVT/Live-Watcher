import SwiftUI

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.openSettings) private var openSettings
    @Environment(\.watcherAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    private enum Page { case all, timeline }
    @State private var page = Page.all
    @State private var scheduleChannel: Channel?
    @FocusState private var settingsFocused: Bool
    @State private var adding = false
    @State private var widgetHelp = false
    @State private var removing: Channel?
    @State private var notificationChannel: Channel?

    private var theme: AppTheme { AppTheme(palette: appearance.palette, scheme: colorScheme) }
    private var fontSize: CGFloat { CGFloat(appearance.fontSize) }
    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1"
        return "\(version) 测试版"
    }

    var body: some View {
        let ordered = monitor.station.ordered
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(spacing: 20) {
                tab("全部关注", count: ordered.count, selected: page == .all) { page = .all }
                tab("时间线", selected: page == .timeline) { page = .timeline }
                Spacer()
                if page != .timeline {
                    Button {
                        Task { await monitor.refresh() }
                    } label: {
                        Label(monitor.refreshing ? "检测中" : "立即检测", systemImage: "arrow.clockwise")
                            .padding(.horizontal, 6).frame(minHeight: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(theme.secondary)
                        .fixedSize(horizontal: true, vertical: false).dashboardFocus(theme.accent)
                        .disabled(monitor.refreshing || ordered.isEmpty)
                        .keyboardShortcut("r", modifiers: .command)
                }
            }.padding(.horizontal, 32)
                .background(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1).padding(.horizontal, 32) }

            if page == .timeline {
                SchedulePage(channels: ordered, channel: nil)
            } else {
                channelList(ordered: ordered)
                footer
            }
        }
        .font(.system(size: fontSize))
        .foregroundStyle(theme.text).tint(theme.accent).background(theme.page)
        .frame(minWidth: 660, minHeight: 550)
        .sheet(isPresented: $adding) { FollowSheet(monitor: monitor) }
        .sheet(item: $scheduleChannel) { channel in
            SchedulePage(channels: ordered, channel: channel)
                .frame(width: 600, height: 510)
        }
        .sheet(item: $notificationChannel) { channel in
            ChannelNotificationSheet(monitor: monitor, uid: channel.id)
        }
        .alert("移除「\(removing?.room.displayName ?? "")」？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { channel in
            Button("移除", role: .destructive) { monitor.remove(channel.id) }
            Button("取消", role: .cancel) {}
        } message: { _ in Text("移除后将停止检测该直播间。") }
    }

    private func channelList(ordered: [Channel]) -> some View {
        let live = ordered.filter { !$0.unavailable && $0.room.isLive }
        let others = ordered.filter { $0.unavailable || !$0.room.isLive }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let issue = monitor.issue {
                    HStack {
                        Image(systemName: "exclamationmark.circle")
                        Text(issue)
                        Spacer()
                        Button { monitor.issue = nil } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }
                            .buttonStyle(.plain).accessibilityLabel("关闭错误提示")
                    }.padding(12).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
                }
                if ordered.isEmpty {
                    emptyState
                } else {
                    if !live.isEmpty { cards(live, minimumWidth: 270) }
                    if !others.isEmpty {
                        if !live.isEmpty {
                            Text("其他关注").font(.system(size: fontSize, weight: .semibold))
                                .foregroundStyle(theme.secondary).accessibilityAddTraits(.isHeader)
                        }
                        cards(others, minimumWidth: 250)
                    }
                }
            }.padding(.horizontal, 32).padding(.vertical, 18)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                HStack(spacing: 10) { wordmark; versionBadge }.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 6)
                headerActions
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) { wordmark; versionBadge }
                Spacer(minLength: 6)
                headerActions
            }
        }.padding(.horizontal, 32).padding(.vertical, 16)
    }

    private var wordmark: some View {
        HStack(spacing: 10) {
            Aster().fill(theme.accent).frame(width: 27, height: 27).accessibilityHidden(true)
            Text("Live Watcher").font(.custom("Georgia-BoldItalic", size: fontSize + 10)).lineLimit(1)
        }
    }

    private var versionBadge: some View {
        Text(versionLabel).font(.system(size: fontSize - 3, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.secondary)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.line))
            .fixedSize()
    }

    private var headerActions: some View {
        HStack(spacing: 10) {
            Button { openSettings() } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: max(16, fontSize), weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(settingsFocused ? theme.accent.opacity(0.24) : theme.card,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).foregroundStyle(theme.accent)
                .focused($settingsFocused).focusEffectDisabled()
                .help("设置").accessibilityLabel("设置")
            Button { adding = true } label: { Label("添加 UP 主", systemImage: "plus") }
                .buttonStyle(StationButton()).dashboardFocus(theme.accent, inset: false)
                .keyboardShortcut("n", modifiers: .command)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 25, weight: .light))
                .frame(width: 54, height: 54)
                .background(theme.card, in: Circle())
                .accessibilityHidden(true)
            Text("还没有关注的 UP 主")
                .font(.system(size: fontSize + 2, weight: .semibold))
            Text("添加 B 站 UID 或直播间链接，开始接收开播提醒。")
                .foregroundStyle(theme.secondary)
            Button { adding = true } label: { Label("添加第一位 UP 主", systemImage: "plus") }
                .buttonStyle(StationButton()).dashboardFocus(theme.accent, inset: false).padding(.top, 4)
        }.frame(maxWidth: .infinity).padding(.vertical, 27)
    }

    private var footer: some View {
        HStack {
            Circle().fill(monitor.station.channels.isEmpty ? theme.secondary : theme.accent)
                .frame(width: 6, height: 6).accessibilityHidden(true)
            if let date = monitor.station.lastCheck {
                Text("上次检测 " + date.formatted(date: .omitted, time: .standard)).monospacedDigit()
            } else { Text("等待添加关注") }
            Spacer()
            Button { widgetHelp = true } label: {
                Label("桌面小组件", systemImage: "macwindow.badge.plus")
                    .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
            }
                .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
                .dashboardFocus(theme.accent).popover(isPresented: $widgetHelp) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("添加到桌面").font(.system(size: fontSize + 2, weight: .semibold))
                        Text("右键点按桌面，选择「编辑小组件」，搜索「Live Watcher」，然后选取尺寸。")
                        Text("只显示正在直播的 UP 主。直播较多时可用箭头翻页，点按直播标题即可打开直播间。").foregroundStyle(theme.secondary)
                    }.font(.system(size: fontSize)).padding(18).frame(width: 320)
                        .foregroundStyle(theme.text).background(theme.card)
                }
        }.font(.system(size: fontSize - 2)).foregroundStyle(theme.secondary)
            .padding(.horizontal, 32).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    private func tab(_ label: String, count: Int? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: fontSize + 1, weight: selected ? .bold : .medium))
                if let count {
                    Text("\(count)").font(.system(size: fontSize - 3, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(selected ? theme.onAccent : theme.secondary)
                        .background(selected ? theme.accent : theme.card, in: Capsule())
                }
            }.padding(.bottom, 12).padding(.top, 8).contentShape(Rectangle())
                .overlay(alignment: .bottom) { if selected { Rectangle().fill(theme.accent).frame(height: 2) } }
        }.buttonStyle(.plain).foregroundStyle(selected ? theme.text : theme.secondary)
            .fixedSize(horizontal: true, vertical: false).dashboardFocus(theme.accent)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func cards(_ channels: [Channel], minimumWidth: CGFloat) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: 16, alignment: .top)], spacing: 16) {
            ForEach(channels) { channel in
                ChannelCard(channel: channel, theme: theme, fontSize: fontSize,
                            week: { scheduleChannel = channel },
                            configure: { notificationChannel = channel },
                            toggle: { monitor.toggleAlerts(for: channel.id) },
                            remove: { removing = channel })
            }
        }
    }
}

private struct ChannelCard: View {
    let channel: Channel
    let theme: AppTheme
    let fontSize: CGFloat
    let week: () -> Void
    let configure: () -> Void
    let toggle: () -> Void
    let remove: () -> Void

    private var room: Room { channel.room }
    private var isLive: Bool { !channel.unavailable && room.isLive }
    private var signature: String {
        let value = room.signature?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "暂无个性签名" : value
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13)
        VStack(alignment: .leading, spacing: 0) {
            Link(destination: room.webURL) {
                VStack(alignment: .leading, spacing: 0) {
                    if isLive { livePreview }
                    VStack(alignment: .leading, spacing: 8) {
                        identity
                        if isLive {
                            Text(room.displayTitle).font(.system(size: fontSize + 3, weight: .semibold))
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 10) {
                                if !room.subcategory.isEmpty {
                                    Text(room.subcategory).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                Label(Room.onlineRankLabel(room.onlineRankCount), systemImage: "person.2")
                                    .monospacedDigit().fixedSize(horizontal: true, vertical: false)
                                    .help("B 站公开在线榜人数，不是累计观看或全量在线人数。")
                            }.font(.system(size: fontSize - 2)).foregroundStyle(theme.secondary)
                        } else {
                            Text(signature).foregroundStyle(theme.secondary).lineLimit(3, reservesSpace: true)
                            if channel.unavailable {
                                Text("最近成功检测 · " + channel.checked.formatted())
                                    .font(.system(size: fontSize - 2)).foregroundStyle(theme.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).dashboardFocus(theme.accent, radius: 10)
                .help("打开\(room.displayName)的直播间")
            Rectangle().fill(theme.line).frame(height: 1)
            HStack(spacing: 0) {
                Link(destination: room.dynamicURL) {
                    Label("动态", systemImage: "text.bubble")
                        .fixedSize().padding(.leading, 14)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).dashboardFocus(theme.accent)
                    .help("打开\(room.displayName)的 B 站动态页")
                    .accessibilityLabel("\(room.displayName)的 B 站动态")
                Button(action: week) {
                    Label("周表", systemImage: "calendar")
                        .fixedSize().padding(.trailing, 6)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .trailing)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).dashboardFocus(theme.accent)
                    .accessibilityLabel("\(room.displayName)的周表")
                Menu {
                    Button(action: configure) {
                        Label("提醒设置", systemImage: channel.alerts ? "bell" : "bell.slash")
                    }
                    Button(channel.alerts ? "关闭该 UP 主提醒" : "开启该 UP 主提醒", action: toggle)
                    Button("移除关注", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 40, height: 40).contentShape(Rectangle())
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .dashboardFocus(theme.accent).accessibilityLabel("更多操作")
            }.font(.system(size: fontSize - 1)).foregroundStyle(theme.secondary)
        }.foregroundStyle(theme.text).background(theme.card)
            .clipShape(shape).overlay { shape.strokeBorder(isLive ? theme.accent.opacity(0.55) : theme.line).allowsHitTesting(false) }
    }

    private var identity: some View {
        HStack(spacing: 8) {
            ArtworkImage(url: room.face, kind: .avatar) {
                Text(String(room.displayName.prefix(1))).font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }.frame(width: 34, height: 34).background(theme.page).clipShape(Circle()).accessibilityHidden(true)
            Text(room.displayName).font(.system(size: fontSize, weight: .semibold))
                .lineLimit(2)
            Spacer(minLength: 2)
            Text(channel.unavailable ? "待确认" : room.statusLabel)
                .font(.system(size: fontSize - 2, weight: .semibold))
                .foregroundStyle(isLive ? theme.onAccent : theme.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(isLive ? theme.accent : theme.page, in: Capsule())
                .fixedSize()
            Image(systemName: "arrow.up.right").font(.system(size: fontSize - 3, weight: .semibold))
                .foregroundStyle(theme.secondary).accessibilityHidden(true)
        }
    }

    private var livePreview: some View {
        Rectangle().fill(theme.page).aspectRatio(16.0 / 9, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    ArtworkImage(url: room.keyframe, kind: .preview, fallbackURL: room.cover) { image, isCover in
                        image.resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                            .accessibilityHidden(true)
                            .overlay(alignment: .bottomLeading) {
                                Text(isCover ? "直播间封面 · 非实时" : "最近直播画面")
                                    .font(.system(size: fontSize - 2, weight: .medium))
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.black.opacity(0.8), in: Capsule()).padding(10)
                            }
                    } placeholder: {
                        unavailablePreview
                    }
                }
            }
    }

    private var unavailablePreview: some View {
        Label("直播画面暂不可用", systemImage: "photo.on.rectangle")
            .font(.system(size: fontSize - 1)).foregroundStyle(theme.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StationButton: ButtonStyle {
    @Environment(\.watcherAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let theme = AppTheme(palette: appearance.palette, scheme: colorScheme)
        configuration.label.font(.system(size: CGFloat(appearance.fontSize) - 1, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(theme.onAccent)
            .background(theme.accent.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct DashboardFocus: ViewModifier {
    let accent: Color
    let radius: CGFloat
    let inset: Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.focused($focused).focusEffectDisabled()
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(accent, lineWidth: 2)
                        .padding(inset ? 0 : -3)
                        .allowsHitTesting(false)
                }
            }
    }
}

private extension View {
    func dashboardFocus(_ accent: Color, radius: CGFloat = 7, inset: Bool = true) -> some View {
        modifier(DashboardFocus(accent: accent, radius: radius, inset: inset))
    }
}
