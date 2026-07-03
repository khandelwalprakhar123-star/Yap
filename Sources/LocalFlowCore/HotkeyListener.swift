import AppKit
import CoreGraphics
import Foundation

/// Global push-to-talk key via a listen-only CGEventTap.
/// Works with modifier keys (Right Option, Right Command, ...) through
/// flagsChanged events, and with regular keys (F13, ...) through keyDown/keyUp.
/// Requires the Input Monitoring permission.
public final class HotkeyListener {
    /// Keys offered in Settings: (display name, virtual keycode, is a modifier key)
    public static let knownKeys: [(name: String, code: Int64, isModifier: Bool)] = [
        ("Right Option (⌥)", 61, true),
        ("Right Command (⌘)", 54, true),
        ("Right Control (⌃)", 62, true),
        ("F13", 105, false),
        ("F14", 107, false),
        ("F15", 113, false),
    ]

    public enum Backend: String {
        case eventTap = "event tap (Input Monitoring)"
        case nsEventMonitor = "NSEvent monitor (Accessibility)"
    }

    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?
    public private(set) var backend: Backend?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let keyCode: Int64
    private let holdToTalk: Bool
    private var keyIsDown = false
    private var toggledOn = false

    private var isModifierKey: Bool {
        Self.knownKeys.first { $0.code == keyCode }?.isModifier ?? false
    }

    public init(keyCode: Int64, holdToTalk: Bool) {
        self.keyCode = keyCode
        self.holdToTalk = holdToTalk
    }

    public static func inputMonitoringGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// Triggers the system prompt (and adds the app to the Input Monitoring pane).
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    /// Prefers a CGEventTap (needs Input Monitoring). If that can't be created,
    /// falls back to NSEvent global monitors, which macOS allows with just the
    /// Accessibility permission for modifier keys (flagsChanged events).
    public func start() throws {
        stop()
        if (try? startEventTap()) != nil {
            backend = .eventTap
            return
        }
        if isModifierKey, AXIsProcessTrusted() {
            startNSEventMonitors()
            backend = .nsEventMonitor
            return
        }
        throw NSError(domain: "LocalFlow", code: 20, userInfo: [
            NSLocalizedDescriptionKey: """
                Could not listen for the hotkey. Grant Accessibility (enough for \
                modifier-key hotkeys) or Input Monitoring (needed for F-keys) in \
                System Settings → Privacy & Security, then relaunch.
                """
        ])
    }

    private func startEventTap() throws {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let listener = Unmanaged<HotkeyListener>.fromOpaque(userInfo).takeUnretainedValue()
            listener.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw NSError(domain: "LocalFlow", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Could not create the global hotkey event tap."
            ])
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        backend = nil
        keyIsDown = false
    }

    // MARK: - NSEvent monitor backend

    private func startNSEventMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleNSEvent(event)
        }
        // Global monitors don't fire while our own app is frontmost.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
    }

    private func handleNSEvent(_ event: NSEvent) {
        guard Int64(event.keyCode) == keyCode else { return }
        let isDown: Bool
        switch event.type {
        case .flagsChanged:
            let relevantFlags: NSEvent.ModifierFlags
            switch keyCode {
            case 54, 55: relevantFlags = .command
            case 58, 61: relevantFlags = .option
            case 59, 62: relevantFlags = .control
            case 56, 60: relevantFlags = .shift
            default: relevantFlags = []
            }
            isDown = !relevantFlags.isEmpty && event.modifierFlags.contains(relevantFlags)
        case .keyDown: isDown = true
        case .keyUp: isDown = false
        default: return
        }
        process(isDown: isDown)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables taps that stall or after system sleep; re-enable.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == keyCode else { return }

        let isDown: Bool
        switch type {
        case .flagsChanged:
            // For modifier keys the press/release state is encoded in the flags.
            let relevantFlags: CGEventFlags
            switch keyCode {
            case 54, 55: relevantFlags = .maskCommand
            case 58, 61: relevantFlags = .maskAlternate
            case 59, 62: relevantFlags = .maskControl
            case 56, 60: relevantFlags = .maskShift
            default: relevantFlags = []
            }
            isDown = event.flags.contains(relevantFlags) && !relevantFlags.isEmpty
        case .keyDown: isDown = true
        case .keyUp: isDown = false
        default: return
        }

        process(isDown: isDown)
    }

    private func process(isDown: Bool) {
        guard isDown != keyIsDown else { return }  // ignore key-repeat
        keyIsDown = isDown

        if holdToTalk {
            isDown ? onPress?() : onRelease?()
        } else if isDown {
            toggledOn.toggle()
            toggledOn ? onPress?() : onRelease?()
        }
    }
}
