import AppKit
import SwiftUI
import MeetingCore

/// A native menu supplies app icons, keyboard navigation, and VoiceOver for free.
struct ApplicationPicker: NSViewRepresentable {
    @Bindable var model: AppModel
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        button.cell?.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel("音频来源")
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectApplication(_:))
        button.menu?.autoenablesItems = false
        button.menu?.delegate = context.coordinator
        context.coordinator.button = button
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        // Keep AppKit's natural control height; only the available width is constrained.
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? intrinsic.width, height: intrinsic.height)
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        // Read observed values even while tracking; keep the menu stable until it closes.
        let choices = model.applicationChoices
        let selectedID = model.targetID
        button.isEnabled = isEnabled
        guard !context.coordinator.isTracking else { return }
        context.coordinator.populate(choices: choices, selectedID: selectedID)
    }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        let model: AppModel
        weak var button: NSPopUpButton?
        var isTracking = false
        private var icons: [String: NSImage] = [:]

        init(model: AppModel) { self.model = model }

        func menuNeedsUpdate(_ menu: NSMenu) {
            isTracking = true
            model.refreshApplications()
            populate(choices: model.applicationChoices, selectedID: model.targetID)
        }

        func menuDidClose(_ menu: NSMenu) { isTracking = false }

        func populate(choices: [TargetApplication], selectedID: String) {
            guard let button, let menu = button.menu else { return }
            menu.removeAllItems()
            let placeholder = NSMenuItem(title: choices.isEmpty ? "暂无推荐应用 · 可显示全部" : "请选择应用", action: nil, keyEquivalent: "")
            placeholder.representedObject = ""
            menu.addItem(placeholder)
            var previousWasPreferred = false
            for app in choices {
                let preferred = app.preferredOrder != nil
                if previousWasPreferred && !preferred { menu.addItem(.separator()) }
                previousWasPreferred = preferred
                let item = NSMenuItem(title: app.name, action: nil, keyEquivalent: "")
                item.representedObject = app.id
                if icons[app.path] == nil {
                    let icon = NSWorkspace.shared.icon(forFile: app.path).copy() as! NSImage
                    icon.size = NSSize(width: 16, height: 16)
                    icons[app.path] = icon
                }
                item.image = icons[app.path]
                item.toolTip = app.bundleIdentifier
                menu.addItem(item)
            }
            button.select(menu.items.first { ($0.representedObject as? String) == selectedID } ?? placeholder)
        }

        @objc func selectApplication(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? String else { return }
            model.targetID = id
        }
    }
}
