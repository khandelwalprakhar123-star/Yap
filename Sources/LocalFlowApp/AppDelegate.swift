import AppKit
import LocalFlowCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = DictationController()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.behavior = []
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.onStateChange = { [weak self] state in
            self?.updateIcon(for: state)
        }
        updateIcon(for: controller.state)
        controller.startup()

        if !allPermissionsGranted() {
            showOnboarding()
        }
    }

    /// Fires when the user double-clicks LocalFlow.app while it's already
    /// running. Menu-bar apps show nothing by default, which reads as
    /// "the app is not opening" — so always surface a window.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if allPermissionsGranted() {
            showSettings()
        } else {
            showOnboarding()
        }
        return true
    }

    private func allPermissionsGranted() -> Bool {
        AudioRecorder.microphonePermissionGranted()
            && HotkeyListener.inputMonitoringGranted()
            && TextInjector.accessibilityGranted()
    }

    // MARK: - Status icon

    private func updateIcon(for state: DictationController.State) {
        guard let button = statusItem.button else { return }
        let (symbol, tint): (String, NSColor?) = switch state {
        case .loadingModels: ("hourglass", nil)
        case .idle: ("mic", nil)
        case .recording: ("record.circle.fill", .systemRed)
        case .transcribing, .cleaning: ("waveform", .systemOrange)
        case .error: ("exclamationmark.triangle.fill", .systemYellow)
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: state.label)
        if let tint {
            button.image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
            button.image?.isTemplate = false
        } else {
            button.image = image
            button.image?.isTemplate = true
        }
        button.toolTip = "LocalFlow — \(state.label)"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: controller.state.label, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let keyName = HotkeyListener.knownKeys
            .first { $0.code == controller.config.hotkeyKeyCode }?.name ?? "hotkey"
        let mode = controller.config.holdToTalk ? "Hold" : "Tap"
        let hint = NSMenuItem(
            title: controller.hotkeyActive
                ? "\(mode) \(keyName) to dictate"
                : "Hotkey inactive — grant Input Monitoring",
            action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        if let model = controller.cleanupModel, controller.config.cleanupEnabled {
            let cleanup = NSMenuItem(title: "Cleanup: \(model)", action: nil, keyEquivalent: "")
            cleanup.isEnabled = false
            menu.addItem(cleanup)
        }

        menu.addItem(.separator())

        if !controller.lastTranscript.isEmpty {
            let preview = controller.lastTranscript.count > 60
                ? String(controller.lastTranscript.prefix(60)) + "…"
                : controller.lastTranscript
            let last = NSMenuItem(title: "“\(preview)”", action: nil, keyEquivalent: "")
            last.isEnabled = false
            menu.addItem(last)
            menu.addItem(withTitle: "Copy Last Transcript",
                         action: #selector(copyLastTranscript), keyEquivalent: "c")
                .target = self
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Permissions…", action: #selector(showOnboardingItem), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LocalFlow", action: #selector(quit), keyEquivalent: "q")
            .target = self
    }

    @objc private func copyLastTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.lastTranscript, forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Windows

    @objc private func showSettings() {
        settingsWindow?.close()
        let window = makeWindow(title: "LocalFlow Settings")
        window.contentViewController = NSHostingController(
            rootView: SettingsView(controller: controller) { [weak self] in
                self?.settingsWindow?.close()
                self?.settingsWindow = nil
            })
        settingsWindow = window
        present(window)
    }

    @objc private func showOnboardingItem() { showOnboarding() }

    private func showOnboarding() {
        onboardingWindow?.close()
        let window = makeWindow(title: "Welcome to LocalFlow")
        window.contentViewController = NSHostingController(
            rootView: OnboardingView { [weak self] in
                guard let self else { return }
                if !self.controller.hotkeyActive {
                    self.controller.startHotkeyIfPossible()
                }
            })
        onboardingWindow = window
        present(window)
    }

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        // Menu-bar (.accessory) apps have no dock presence, so their windows
        // can open buried under other apps; keep ours on top.
        window.level = .floating
        return window
    }

    private func present(_ window: NSWindow) {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
