import SwiftUI

struct SchedulePage: View {
    let channels: [Channel]
    let channel: Channel?
    @EnvironmentObject private var store: ScheduleStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.watcherAppearance) private var appearance
    @Environment(\.colorScheme) private var scheme
    @State private var selectedWeek: Date?
    @State private var showingPast = false
    @State private var choosingSources = false
    @State private var scrollReset = 0
    @State private var adding = false
    @State private var editing: ScheduleSubscription?

    private var theme: AppTheme { AppTheme(palette: appearance.palette, scheme: scheme) }
    private var feeds: [ScheduleSubscription] {
        store.subscriptions.filter { channel == nil || $0.record.channelID == channel?.id }
    }

    var body: some View {
        TimelineView(.everyMinute) { clock in
            page(at: clock.date)
        }
    }

    private func page(at now: Date) -> some View {
        let week = ScheduleWeek.interval(containing: selectedWeek ?? now)
        let visible = channel == nil ? feeds.filter(store.showsOnTimeline) : feeds
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(channel.map { $0.room.displayName + "的周表" } ?? "订阅日程")
                    .font(.system(size: appearance.fontSize + 5, weight: .bold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if !feeds.isEmpty {
                    if channel == nil {
                        Button { choosingSources.toggle() } label: {
                            Label("显示主播", systemImage: "line.3.horizontal.decrease.circle")
                        }.fixedSize().popover(isPresented: $choosingSources) { timelineSettings }
                    }
                    Menu("管理订阅") {
                        ForEach(feeds) { feed in
                            let owner = feed.displayName(channels: channels)
                            Button(owner == feed.name ? feed.name : owner + " · " + feed.name) { editing = feed }
                        }
                    }.fixedSize()
                }
                Button { adding = true } label: {
                    Label("导入订阅", systemImage: "plus")
                }.buttonStyle(StationButton()).disabled(store.storageError != nil)
            }.padding(.bottom, 14)
            if !feeds.isEmpty {
                HStack(spacing: 8) {
                    Text(week.start.formatted(.dateTime.year().month().day().locale(Self.chinese)) + " – " +
                         week.end.addingTimeInterval(-1).formatted(.dateTime.month().day().locale(Self.chinese)))
                        .monospacedDigit().fontWeight(.medium)
                    Spacer()
                    Button { moveWeek(-1, from: week.start, now: now) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上一周")
                    Button("本周") {
                        selectedWeek = nil
                        showingPast = false
                        scrollReset += 1
                    }
                    Button { moveWeek(1, from: week.start, now: now) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下一周")
                }.padding(.bottom, 12)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = store.storageError {
                        Label(error, systemImage: "exclamationmark.circle")
                    }
                    ForEach(visible) { feed in
                        if let error = store.errors[feed.id] {
                            Label("\(feed.displayName(channels: channels)) 更新失败 · \(error)", systemImage: "exclamationmark.circle")
                                .foregroundStyle(theme.secondary)
                        }
                    }
                    if feeds.isEmpty {
                        empty(channel == nil ? "还没有订阅日程" : "这位 UP 主还没有周表",
                              detail: "导入 ICS 订阅链接后，日程会显示在这里。")
                    } else if visible.isEmpty {
                        empty("时间线未选择周表", detail: "在「显示主播」中勾选要查看的周表。")
                    } else {
                        agenda(entries: ScheduleWeek.entries(visible, in: week), week: week, now: now)
                    }
                }.padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
            }.id(week.start).id(scrollReset)
            Divider()
            HStack {
                if !feeds.isEmpty {
                    let syncing = feeds.contains { store.refreshing.contains($0.id) }
                    Button { Task { await store.refresh(channelID: channel?.id) } } label: {
                        Label(syncing ? "同步中…" : "刷新日程", systemImage: "arrow.clockwise")
                    }.disabled(syncing)
                    Text(TimeZone.current.identifier).foregroundStyle(theme.secondary)
                        .help("日程按本机时区显示")
                }
                Spacer()
                if channel != nil {
                    Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }.padding(.top, 10)
        }
        .padding(.horizontal, channel == nil ? 32 : 24).padding(.vertical, 16)
        .font(.system(size: appearance.fontSize)).foregroundStyle(theme.text).background(theme.page).tint(theme.accent)
        .sheet(isPresented: $adding) { SubscriptionEditor(channels: channels, channel: channel, feed: nil) }
        .sheet(item: $editing) { feed in SubscriptionEditor(channels: channels, channel: channel, feed: feed) }
    }

    private static let chinese = Locale(identifier: "zh_CN")
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var timelineSettings: some View {
        let choices = Dictionary(grouping: feeds, by: \.timelineSourceID).compactMap(\.value.first).sorted {
            $0.displayName(channels: channels).localizedStandardCompare($1.displayName(channels: channels)) == .orderedAscending
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("在时间线中显示").fontWeight(.semibold)
            ViewThatFits(in: .vertical) {
                sourceToggles(choices)
                ScrollView { sourceToggles(choices) }
            }
        }.padding(16).frame(width: 260, alignment: .leading).frame(maxHeight: 360)
            .foregroundStyle(theme.text).background(theme.card)
    }

    private func sourceToggles(_ choices: [ScheduleSubscription]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(choices, id: \.timelineSourceID) { feed in
                Toggle(isOn: Binding(get: { store.showsOnTimeline(feed) },
                                     set: { store.setTimelineVisible($0, for: feed) })) {
                    Text(feed.displayName(channels: channels)).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.toggleStyle(.checkbox)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func moveWeek(_ direction: Int, from start: Date, now: Date) {
        let target = ScheduleWeek.calendar.date(byAdding: .weekOfYear, value: direction, to: start)
        selectedWeek = target == ScheduleWeek.interval(containing: now).start ? nil : target
        showingPast = false
    }

    @ViewBuilder private func agenda(entries: [ScheduleWeek.Entry], week: DateInterval, now: Date) -> some View {
        let current = week.start <= now && now < week.end
        if current {
            HStack(spacing: 8) {
                Label("现在 " + Self.clock.string(from: now), systemImage: "clock")
                    .fontWeight(.semibold).monospacedDigit()
                Text(now.formatted(.dateTime.month().day().weekday(.wide).locale(Self.chinese)))
                Rectangle().fill(theme.line).frame(height: 1).accessibilityHidden(true)
            }.foregroundStyle(theme.accent)
        }
        if entries.isEmpty {
            empty("这一周暂无日程", detail: "可以切换到其他周，或刷新订阅。")
        } else if current {
            let remaining = entries.filter { !$0.hasEnded(at: now) }
            if remaining.isEmpty {
                Text("本周后续暂无日程").foregroundStyle(theme.secondary).padding(.vertical, 6)
            } else {
                days(remaining, starting: ScheduleWeek.calendar.startOfDay(for: now), until: week.end,
                     showEmpty: channel != nil, now: now)
            }
            let past = entries.filter { $0.hasEnded(at: now) }
            if !past.isEmpty {
                DisclosureGroup("已结束的日程（\(past.count)）", isExpanded: $showingPast) {
                    days(past, starting: week.start, until: week.end, showEmpty: false, now: nil)
                        .padding(.top, 8)
                }.padding(.vertical, 4)
            }
        } else {
            days(entries, starting: week.start, until: week.end, showEmpty: channel != nil, now: nil)
        }
    }

    private func days(_ entries: [ScheduleWeek.Entry], starting firstDay: Date, until end: Date,
                      showEmpty: Bool, now: Date?) -> some View {
        let calendar = ScheduleWeek.calendar
        let count = calendar.dateComponents([.day], from: firstDay, to: end).day ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<count, id: \.self) { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: firstDay)!
                let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
                let rows = entries.filter {
                    let start = $0.occurrence.start
                    if channel == nil { return max(start, firstDay) >= day && start < nextDay }
                    return start < nextDay && (start >= day || $0.occurrence.end > day)
                }
                if showEmpty || !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(day.formatted(.dateTime.month().day().weekday(.wide).locale(Self.chinese)))
                            .fontWeight(.semibold).foregroundStyle(calendar.isDateInToday(day) ? theme.accent : theme.text)
                            .accessibilityAddTraits(.isHeader)
                        if rows.isEmpty { Text("暂无日程").foregroundStyle(theme.secondary) }
                        ForEach(rows) { entry in
                            eventRow(entry, day: day, ongoing: now.map { entry.isOngoing(at: $0) && calendar.isDate($0, inSameDayAs: day) } ?? false)
                        }
                    }
                }
            }
        }
    }

    private func eventRow(_ entry: ScheduleWeek.Entry, day: Date, ongoing: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(theme.accent).frame(width: 7, height: 7).padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(timeLabel(entry, day: day))
                    if ongoing { Text("进行中").fontWeight(.semibold) }
                }.font(.system(size: appearance.fontSize - 1, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.accent)
                Text(entry.occurrence.event.title).fontWeight(.medium)
                if channel == nil {
                    Text(entry.source.displayName(channels: channels)).font(.system(size: appearance.fontSize - 1))
                        .foregroundStyle(theme.secondary)
                }
            }
            Spacer(minLength: 0)
        }.padding(12).background(theme.card, in: RoundedRectangle(cornerRadius: 8))
    }

    private func timeLabel(_ entry: ScheduleWeek.Entry, day: Date) -> String {
        let event = entry.occurrence
        let calendar = ScheduleWeek.calendar
        func shortDate(_ date: Date) -> String { date.formatted(.dateTime.month().day().locale(Self.chinese)) }
        if event.isAllDay {
            let last = max(event.start, event.end.addingTimeInterval(-1))
            return calendar.isDate(event.start, inSameDayAs: last) ? "全天" : "全天 · \(shortDate(event.start)) – \(shortDate(last))"
        }
        func time(_ date: Date) -> String {
            let clock = Self.clock.string(from: date)
            return calendar.isDate(date, inSameDayAs: day) ? clock : shortDate(date) + " " + clock
        }
        return event.end > event.start ? time(event.start) + " – " + time(event.end) : time(event.start)
    }

    private func empty(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar").font(.title).foregroundStyle(theme.accent).accessibilityHidden(true)
            Text(title).fontWeight(.semibold)
            Text(detail).foregroundStyle(theme.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 34)
    }
}

private struct SubscriptionEditor: View {
    let channels: [Channel]
    let channel: Channel?
    let feed: ScheduleSubscription?
    @EnvironmentObject private var store: ScheduleStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.watcherAppearance) private var appearance
    @Environment(\.colorScheme) private var scheme
    @State private var input: String
    @State private var selected: Int64?
    @State private var working = false
    @State private var removing = false
    @State private var error: String?

    init(channels: [Channel], channel: Channel?, feed: ScheduleSubscription?) {
        self.channels = channels
        self.channel = channel
        self.feed = feed
        _input = State(initialValue: feed?.record.url.absoluteString ?? "")
        _selected = State(initialValue: channel?.id ?? feed?.record.channelID)
    }

    var body: some View {
        let theme = AppTheme(palette: appearance.palette, scheme: scheme)
        VStack(alignment: .leading, spacing: 14) {
            Text(feed == nil ? "导入 ICS 订阅" : "编辑订阅").font(.title2.bold())
            TextField("ICS 订阅链接", text: $input, prompt: Text("https://…/schedule.ics"))
                .textFieldStyle(.roundedBorder)
            if let channel { Text("关联 UP 主 · " + channel.room.displayName) }
            else {
                Picker("关联 UP 主", selection: $selected) {
                    Text("独立订阅").tag(nil as Int64?)
                    ForEach(channels) { channel in Text(channel.room.displayName).tag(Optional(channel.id)) }
                    if let id = feed?.record.channelID, !channels.contains(where: { $0.id == id }) {
                        Text("UID \(id)").tag(Optional(id))
                    }
                }
            }
            if feed == nil && (channel == nil || channel?.room.roomID == 25034104) {
                Button("使用明前奶绿的订阅链接") {
                    input = "https://laplace.live/schedule.ics"
                    if selected == nil { selected = channels.first { $0.room.roomID == 25034104 }?.id }
                }
                    .buttonStyle(.link)
            }
            if let feed {
                Text("最近同步 · " + feed.record.updated.formatted()).foregroundStyle(theme.secondary)
                if !feed.document.calendar.warnings.isEmpty {
                    DisclosureGroup("日历解析提示（\(feed.document.calendar.warnings.count)）") {
                        ScrollView { Text(feed.document.calendar.warnings.joined(separator: "\n")).textSelection(.enabled) }.frame(maxHeight: 80)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if feed != nil {
                    Button("取消订阅", role: .destructive) { removing = true }
                }
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(feed == nil ? "订阅" : "保存") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(working).interactiveDismissDisabled(working)
        .padding(24).frame(width: 460)
        .font(.system(size: appearance.fontSize)).foregroundStyle(theme.text).background(theme.page).tint(theme.accent)
        .alert("取消这份日程订阅？", isPresented: $removing) {
            Button("取消订阅", role: .destructive) {
                guard let feed else { return }
                do { try store.remove(feed.id); dismiss() } catch { self.error = error.localizedDescription }
            }
            Button("保留订阅", role: .cancel) {}
        }
    }

    private func save() {
        guard !working else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await store.save(input: input, channelID: selected, editing: feed?.id)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
