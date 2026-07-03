import AppKit
import CoreGraphics
import Foundation

/// Injects text into the frontmost app's focused field.
/// Default path: put text on the pasteboard, synthesize Cmd+V, then restore
/// whatever was on the clipboard before. Fallback path: type the text as
/// Unicode keystrokes (works in apps that block programmatic paste).
/// Both paths require the Accessibility permission to post events.
public enum TextInjector {
    public static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system Accessibility prompt (and adds the app to the pane).
    public static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    public static func inject(_ text: String, method: String) {
        method == "type" ? typeUnicode(text) : pastePreservingClipboard(text)
    }

    // MARK: - Paste path

    public static func pastePreservingClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Snapshot every item and every representation currently on the clipboard.
        let saved: [[NSPasteboard.PasteboardType: Data]] =
            (pasteboard.pasteboardItems ?? []).map { item in
                var reps: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { reps[type] = data }
                }
                return reps
            }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        synthesizeCmdV()

        // Give the target app time to read the pasteboard before restoring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            pasteboard.clearContents()
            guard !saved.isEmpty else { return }
            let items = saved.map { reps -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in reps { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
        }
    }

    private static func synthesizeCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9  // kVK_ANSI_V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Keystroke path

    public static func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        // keyboardSetUnicodeString caps out around 20 UTF-16 units per event.
        let chunkSize = 18
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + chunkSize, units.count)])
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
            }
            index += chunkSize
            usleep(8_000)  // let slow apps keep up
        }
    }
}
