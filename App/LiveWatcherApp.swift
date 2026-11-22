import AppKit
import SwiftUI

@main
struct LiveWatcherApp: App {
    @NSApplicationDelegateAdaptor(NotificationDelegate.self) private var delegate
    @StateObject private var monitor = Monitor()
    @StateObject private var schedules = ScheduleStore()
    @Environment(\.openWindow) private var openWindow

    private var appearance: Appearance { monitor.station.preferences.appearance }

    var body: some Scene {
        Window("Live Watcher", id: "station") {
            Dashboard(monitor: monitor)
                .environmentObject(schedules)
                .environment(\.watcherAppearance, appearance)
                .task { monitor.start(); schedules.start() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    Task { await monitor.refresh() }
                }
                .onOpenURL { url in
                    if let room = RoomRoute.destination(for: url) { NSWorkspace.shared.open(room) }
                }
        }
        .defaultSize(width: 900, height: 670)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        Settings {
            SettingsPanel(monitor: monitor)
                .environment(\.watcherAppearance, appearance)
        }
        MenuBarExtra {
            Button("打开直播观测站") { openWindow(id: "station"); NSApp.activate(ignoringOtherApps: true) }
            if !monitor.station.live.isEmpty {
                Divider()
                ForEach(monitor.station.live) { channel in
                    Button(channel.room.displayName + " · " + channel.room.displayTitle) { NSWorkspace.shared.open(channel.room.webURL) }
                }
            }
            Button("立即检测") { Task { await monitor.refresh() } }.disabled(monitor.station.channels.isEmpty)
            SettingsLink { Text("设置…") }
            Divider()
            Button("退出 Live Watcher") { NSApp.terminate(nil) }
        } label: {
            Label("直播观测站", systemImage: monitor.station.live.isEmpty ? "antenna.radiowaves.left.and.right" : "dot.radiowaves.left.and.right")
                .task { monitor.start(); schedules.start() }
        }
    }
}
