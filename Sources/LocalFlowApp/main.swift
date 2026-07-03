import AppKit

// LocalFlow — fully local dictation for macOS.
// Menu-bar only (no dock icon): activation policy .accessory + LSUIElement in Info.plist.
let delegate = MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    return delegate
}
MainActor.assumeIsolated {
    NSApplication.shared.run()
}
_ = delegate
