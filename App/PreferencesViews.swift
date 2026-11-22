import SwiftUI
import UserNotifications

struct FollowSheet: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.watcherAppearance) private var appearance
    @State private var input = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        let theme = AppTheme(palette: appearance.palette, scheme: scheme)
        VStack(alignment: .leading, spacing: 16) {
            Aster().fill(theme.accent).frame(width: 26, height: 26)
            Text("添加 UP 主").font(.title.bold())
            Text("输入 UID，或粘贴 B 站个人空间、直播间链接。").foregroundStyle(theme.secondary)
            TextField("UID 或链接", text: $input).textFieldStyle(.roundedBorder)
                .focused($focused).disabled(working).onSubmit { follow() }
            if let error { Text(error).foregroundStyle(Color.red).font(.callout).textSelection(.enabled) }
            HStack {
                if working { ProgressView().controlSize(.small); Text("正在查找直播间…").font(.caption) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button("添加关注") { follow() }.keyboardShortcut(.defaultAction)
                    .disabled(working || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.top, 5)
        }.padding(26).frame(width: 440).background(theme.page).foregroundStyle(theme.text)
            .font(.system(size: CGFloat(appearance.fontSize)))
            .tint(theme.accent).onAppear { focused = true }.interactiveDismissDisabled(working)
    }
    private func follow() {
        guard !working, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await monitor.follow(input); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct SettingsPanel: View {
    private enum Tab: Hashable { case notifications, appearance }

    @ObservedObject var monitor: Monitor
    @Environment(\.colorScheme) private var scheme
    @Environment(\.watcherAppearance) private var appearance
    @State private var seconds = ""
    @State private var validation: String?
    @State private var scopedUID: Int64?
    @State private var tab: Tab = .notifications

    private var prefs: Preferences { monitor.station.preferences }
    private var theme: AppTheme { AppTheme(palette: appearance.palette, scheme: scheme) }

    var body: some View {
        VStack(spacing: 0) {
            PreferenceChoices("设置页面", selection: $tab, theme: theme, options: [
                (.notifications, "检测与提醒", "bell"),
                (.appearance, "外观", "paintpalette")
            ]).padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .notifications: notifications
                    case .appearance: appearanceControls
                    }
                }.padding(20)
            }.id(tab)
        }
        .frame(width: 560, height: tab == .notifications ? 540 : 310)
        .background(theme.page)
        .foregroundStyle(theme.text)
        .tint(theme.accent)
        .font(.system(size: CGFloat(appearance.fontSize)))
        .onAppear { seconds = String(prefs.interval) }
        .task { await monitor.loadSettings() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await monitor.checkAuthorization() }
        }
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 15) {
            PreferenceFormRow("检测间隔") { intervalControls }
            Text(validation ?? "可设为 15–3600 秒。关闭主窗口后，应用仍会在菜单栏检测。")
                .font(.callout).foregroundStyle(validation == nil ? theme.secondary : .red)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle(isOn: bind(\.alerts)) { Text("开播通知").fixedSize(horizontal: false, vertical: true) }
                .toggleStyle(.switch)
                .preferenceFocus(theme)
            Toggle("播放提醒声音", isOn: bind(\.sound))
                .toggleStyle(PreferenceCheckboxStyle(theme: theme))
                .disabled(!prefs.alerts)
            if prefs.alerts && monitor.authorization == .denied {
                Button("在系统设置中允许通知 ↗") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=cn.guzhengsvt.LiveWatcher") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(PreferenceButtonStyle(theme: theme))
                .preferenceFocus(theme)
            } else if prefs.alerts && monitor.authorization == .notDetermined {
                Button("向 macOS 请求通知权限") { Task { await monitor.requestAuthorizationIfNeeded() } }
                    .buttonStyle(PreferenceButtonStyle(theme: theme))
                    .preferenceFocus(theme)
            }
            Divider()
            PreferenceFormRow("提醒分区") {
                Picker("提醒设置应用范围", selection: $scopedUID) {
                    Text("全局默认").tag(nil as Int64?)
                    ForEach(monitor.station.ordered) { channel in
                        Text(channel.room.displayName).tag(Optional(channel.id))
                    }
                }.labelsHidden().pickerStyle(.menu)
            }
            if let channel = monitor.station.channels.first(where: { $0.id == scopedUID }) {
                ChannelRulesControls(monitor: monitor, channel: channel)
            } else {
                Text("全局分区适用于未单独自定义的 UP 主。分区筛选只影响通知，不隐藏直播卡片。")
                    .font(.callout).foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CategoryRulesEditor(areas: availableAreas(for: monitor), rules: bind(\.effectiveRules))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var intervalControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { intervalField; applyButton }
            VStack(alignment: .leading, spacing: 8) { intervalField; applyButton }
        }
    }

    private var intervalField: some View {
        HStack(spacing: 8) {
            TextField("秒", text: $seconds)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .onSubmit { applyInterval() }
                .preferenceFocus(theme)
                .frame(width: appearance.fontSize * 4)
            Text("秒").foregroundStyle(theme.secondary).fixedSize()
        }
    }

    private var applyButton: some View {
        Button("应用") { applyInterval() }
            .buttonStyle(PreferenceButtonStyle(theme: theme, highlighted: true))
            .preferenceFocus(theme)
            .disabled(seconds == String(prefs.interval))
    }

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            PreferenceChoices("日间 / 黑暗模式", selection: bind(\.appearance.mode), theme: theme, options: [
                (.system, "跟随系统", nil), (.light, "日间", nil), (.dark, "黑暗", nil)
            ])
            Picker("配色", selection: Binding(get: { prefs.appearance.palette }, set: { palette in
                monitor.configure { p in
                    p.appearance.palette = palette
                    if palette == .white { p.appearance.mode = .light }
                    if palette == .black { p.appearance.mode = .dark }
                }
            })) {
                Text("奶绿").tag(AppearancePalette.mint)
                Text("纯白").tag(AppearancePalette.white)
                Text("纯黑").tag(AppearancePalette.black)
                Text("Claude 风格").tag(AppearancePalette.claude)
                Text("冬季").tag(AppearancePalette.winter)
            }
            HStack(spacing: 12) {
                Slider(value: Binding(
                    get: { prefs.appearance.fontSize },
                    set: { value in monitor.configure { $0.appearance.fontSize = value } }
                ), in: 12...22, step: 1) { Text("字号") }
                Text("\(Int(prefs.appearance.fontSize)) pt").monospacedDigit()
                    .foregroundStyle(theme.secondary).fixedSize()
            }
            Text("选择纯白或纯黑会同时切到日间或黑暗模式；桌面小组件继续跟随系统外观。")
                .font(.callout).foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bind<Value>(_ key: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { prefs[keyPath: key] }, set: { value in monitor.configure { $0[keyPath: key] = value } })
    }
    private func applyInterval() {
        guard let value = Int(seconds), Preferences.intervalRange.contains(value) else {
            validation = "请输入 15 到 3600 之间的整数。"
            return
        }
        monitor.configure { $0.interval = value }
        seconds = String(prefs.interval)
        validation = nil
    }
}

struct ChannelNotificationSheet: View {
    @ObservedObject var monitor: Monitor
    let uid: Int64
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.watcherAppearance) private var appearance

    var body: some View {
        let theme = AppTheme(palette: appearance.palette, scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                if let channel = monitor.station.channels.first(where: { $0.id == uid }) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(channel.room.displayName) · 开播提醒").font(.title2.bold())
                            .fixedSize(horizontal: false, vertical: true)
                        ChannelRulesControls(monitor: monitor, channel: channel)
                    }.padding(24)
                }
            }
            Divider()
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PreferenceButtonStyle(theme: theme, highlighted: true))
                .preferenceFocus(theme)
                .padding(16).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: 500, height: 510)
        .background(theme.page)
        .foregroundStyle(theme.text)
        .tint(theme.accent)
        .font(.system(size: CGFloat(appearance.fontSize)))
        .task { await monitor.loadSettings() }
    }
}

private struct ChannelRulesControls: View {
    @ObservedObject var monitor: Monitor
    let channel: Channel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.watcherAppearance) private var appearance

    var body: some View {
        let theme = AppTheme(palette: appearance.palette, scheme: scheme)
        let global = monitor.station.preferences
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { channel.alerts }, set: { newValue in
                if newValue != channel.alerts { monitor.toggleAlerts(for: channel.id) }
            })) {
                Text("此 UP 主的开播提醒").fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch)
            .preferenceFocus(theme)
            PreferenceChoices("分区规则", selection: Binding(get: { channel.categoryRules != nil }, set: { custom in
                monitor.setCategoryRules(custom ? global.effectiveRules : nil, for: channel.id)
            }), theme: theme, options: [(false, "跟随全局", nil), (true, "自定义分区", nil)])
            if !global.alerts {
                Text("全局开播通知已关闭，此处设置会保留。")
                    .font(.callout).foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if channel.categoryRules != nil {
                Text("自定义分区只覆盖全局分区选择；仍受全局通知和此 UP 主开播提醒开关控制。")
                    .font(.callout).foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CategoryRulesEditor(areas: availableAreas(for: monitor), rules: Binding(
                    get: { monitor.station.channels.first(where: { $0.id == channel.id })?.categoryRules ?? monitor.station.preferences.effectiveRules },
                    set: { monitor.setCategoryRules($0, for: channel.id) }
                ))
            } else {
                Text("此 UP 主使用全局分区规则。")
                    .font(.callout).foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CategoryRulesEditor: View {
    let areas: [LiveArea]
    @Binding var rules: CategoryRules
    @Environment(\.colorScheme) private var scheme
    @Environment(\.watcherAppearance) private var appearance

    var body: some View {
        let theme = AppTheme(palette: appearance.palette, scheme: scheme)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 12) {
                Text("展开一级分区可单独设置二级分区；切换一级分区会同时设置其下全部二级分区。")
                    .font(.callout).foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("全部开启") { rules = CategoryRules() }
                    .buttonStyle(PreferenceButtonStyle(theme: theme))
                    .preferenceFocus(theme)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(rules == CategoryRules())
            }.padding(.bottom, 4)
            ForEach(areas) { area in
                areaRow(area, theme: theme)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private func areaRow(_ area: LiveArea, theme: AppTheme) -> some View {
        let enabled = rules.allows(area.id)
        let hasExceptions = area.children.contains { rules.allows(area.id, $0.id) != enabled }
        let groupToggle = Toggle(area.name + "提醒", isOn: Binding(get: { rules.allows(area.id) }, set: { enabled in
            rules.setGroup(area.id, allowed: enabled)
        })).labelsHidden().toggleStyle(.switch).controlSize(.small).accessibilityLabel("\(area.name)提醒")
            .preferenceFocus(theme)
        let name = Text(area.name).fixedSize(horizontal: false, vertical: true)

        if area.children.isEmpty {
            HStack { name; Spacer(); groupToggle }
        } else {
            HStack(alignment: .top, spacing: 12) {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(area.children, id: \.id) { child in
                            Toggle(child.name, isOn: Binding(get: { rules.allows(area.id, child.id) }, set: { enabled in
                                rules.setSubgroup(child.id, in: area.id, allowed: enabled)
                            })).toggleStyle(PreferenceCheckboxStyle(theme: theme))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                } label: {
                    if hasExceptions {
                        let note = Text("含单独设置").font(.caption).foregroundStyle(theme.secondary)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) { name; note }
                            VStack(alignment: .leading, spacing: 3) { name; note }
                        }
                    } else {
                        name
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                groupToggle
            }
        }
    }
}

private struct PreferenceFormRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                label
                Spacer(minLength: 0)
                content
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                content
            }
        }
    }

    private var label: some View {
        Text(title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
    }
}

private struct PreferenceChoices<Selection: Hashable>: View {
    let title: String
    @Binding var selection: Selection
    let theme: AppTheme
    let options: [(value: Selection, title: String, icon: String?)]
    @FocusState private var focused: Selection?

    init(_ title: String, selection: Binding<Selection>, theme: AppTheme,
         options: [(value: Selection, title: String, icon: String?)]) {
        self.title = title
        _selection = selection
        self.theme = theme
        self.options = options
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.value) { option in
                Button {
                    select(option.value)
                } label: {
                    Group {
                        if let icon = option.icon {
                            Label(option.title, systemImage: icon)
                        } else {
                            Text(option.title)
                        }
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(PreferenceButtonStyle(theme: theme, highlighted: selection == option.value))
                .focused($focused, equals: option.value)
                .preferenceFocusRing(theme, visible: focused == option.value)
                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
                .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                    move(from: option.value, by: press.key == .leftArrow ? -1 : 1)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func select(_ value: Selection) {
        if value != selection { selection = value }
    }

    private func move(from value: Selection, by offset: Int) -> KeyPress.Result {
        guard let index = options.firstIndex(where: { $0.value == value }) else { return .ignored }
        if options.indices.contains(index + offset) {
            let next = options[index + offset].value
            select(next)
            focused = next
        }
        return .handled
    }
}

private struct PreferenceButtonStyle: ButtonStyle {
    let theme: AppTheme
    var highlighted = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(highlighted ? theme.onAccent : theme.text)
            .background(highlighted ? theme.accent : theme.card, in: shape)
            .overlay { if !highlighted { shape.strokeBorder(theme.line) } }
            .contentShape(shape)
            .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.8 : 1)
    }
}

private struct PreferenceCheckboxStyle: ToggleStyle {
    let theme: AppTheme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                let box = RoundedRectangle(cornerRadius: 4)
                box.fill(configuration.isOn ? theme.accent : theme.card)
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.onAccent)
                        } else {
                            box.strokeBorder(theme.secondary)
                        }
                    }
                    .frame(width: 16, height: 16)
                configuration.label.fixedSize(horizontal: false, vertical: true)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .preferenceFocus(theme)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
        }
    }
}

private struct PreferenceFocus: ViewModifier {
    let theme: AppTheme
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.focused($focused).preferenceFocusRing(theme, visible: focused)
    }
}

private extension View {
    func preferenceFocus(_ theme: AppTheme) -> some View {
        modifier(PreferenceFocus(theme: theme))
    }

    func preferenceFocusRing(_ theme: AppTheme, visible: Bool) -> some View {
        focusEffectDisabled().overlay {
            if visible {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(theme.accent, lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

@MainActor
private func availableAreas(for monitor: Monitor) -> [LiveArea] {
    var areas = monitor.areas
    for channel in monitor.station.channels {
        let room = channel.room
        guard room.categoryID > 0, !room.category.isEmpty else { continue }
        let children: [LiveSubarea] = if let id = room.subcategoryID, id > 0, !room.subcategory.isEmpty {
            [.init(id: id, name: room.subcategory)]
        } else { [] }
        if let index = areas.firstIndex(where: { $0.id == room.categoryID }) {
            let area = areas[index]
            if let child = children.first, !area.children.contains(where: { $0.id == child.id }) {
                areas[index] = .init(id: area.id, name: area.name, children: area.children + [child])
            }
        } else {
            areas.append(.init(id: room.categoryID, name: room.category, children: children))
        }
    }
    return areas
}
