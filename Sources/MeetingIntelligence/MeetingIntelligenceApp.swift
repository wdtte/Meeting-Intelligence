import SwiftUI
import AppKit
import MeetingCore

@main
struct MeetingIntelligenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var lifetime = ModelLifetime()
    private var model: AppModel { lifetime.model }
    var body: some Scene {
        Window("Meeting Intelligence", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 620)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1120, height: 780)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.showSettings() }
                    .keyboardShortcut(",").disabled(model.isBusy)
            }
            CommandGroup(replacing: .newItem) {
                Button("新录制") { model.select(nil) }.keyboardShortcut("n").disabled(model.isBusy)
            }
        }
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Label("Meeting Intelligence", systemImage: model.isBusy ? "record.circle.fill" : "waveform")
        }

    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var playbackKeyMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        playbackKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard [49, 123, 124, 125, 126].contains(event.keyCode),
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      NSApp.isActive, let window = event.window, window === NSApp.mainWindow,
                      NSApp.modalWindow == nil, window.attachedSheet == nil,
                      !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else { return false }
                if event.keyCode == 125 || event.keyCode == 126 {
                    return self?.model?.navigateRecording(event.keyCode == 126 ? .previous : .next) == true
                }
                if event.keyCode == 49 {
                    if event.isARepeat { return self?.model?.playbackRecording != nil }
                    return self?.model?.togglePlayback() == true
                }
                return self?.model?.navigateTranscript(event.keyCode == 123 ? .previous : .next) == true
            }
            return handled ? nil : event
        }
        let info = Bundle.main.infoDictionary ?? [:]
        DiagnosticLog.shared.record("app.launch", fields: [
            "version": info["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info["CFBundleVersion"] as? String ?? "unknown",
            "commit": info["MICommit"] as? String ?? "unknown",
            "build_time": info["MIBuildTime"] as? String ?? "unknown"
        ])
        NSApp.setActivationPolicy(.regular)
        // Set the running Dock tile directly as well as declaring the bundle icon.
        // LaunchServices may still have the first development build cached.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
            NSApp.dockTile.display()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let playbackKeyMonitor { NSEvent.removeMonitor(playbackKeyMonitor) }
        DiagnosticLog.shared.record("app.terminate")
        DiagnosticLog.shared.flush()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else { return .terminateNow }
        guard model.state == .recording else { return .terminateCancel }
        let alert = NSAlert()
        alert.messageText = "结束录音并退出？"
        alert.informativeText = "当前录音会先完成保存。"
        alert.addButton(withTitle: "结束并退出"); alert.addButton(withTitle: "继续录音")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            let saved = await model.stop()
            NSApp.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}

private struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("Meeting Intelligence")
        if model.isBusy {
            Text("正在录制 · \(model.captureName)")
            Button("结束录音") { Task { await model.stop() } }.disabled(model.state != .recording)
        }
        Button("打开主窗口") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("设置…") {
            model.showSettings(); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
        }.disabled(model.isBusy)
        Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

// Keep the observable model alive across window and menu bar scene updates.
@MainActor private final class ModelLifetime: ObservableObject {
    let model = AppModel()
}
