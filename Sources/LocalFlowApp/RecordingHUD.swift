import AppKit
import SwiftUI

/// Floating pill at the bottom-center of the screen so you always know when
/// LocalFlow is listening or still processing. Click-through, all Spaces,
/// never steals focus from the app you're dictating into.
@MainActor
final class RecordingHUD {
    private var panel: NSPanel?
    private var host: NSHostingView<HUDView>?

    /// Reads the current mic input level (0...1) while recording.
    var levelProvider: () -> Float = { 0 }

    func update(state: DictationController.State) {
        switch state {
        case .recording:
            show(text: "Listening…", color: .red, showLevel: true)
        case .transcribing:
            show(text: "Transcribing…", color: .orange, showLevel: false)
        case .cleaning:
            show(text: "Cleaning up…", color: .orange, showLevel: false)
        default:
            hide()
        }
    }

    private func show(text: String, color: Color, showLevel: Bool) {
        let view = HUDView(text: text, color: color, showLevel: showLevel,
                           levelProvider: levelProvider)
        if let panel, let host {
            host.rootView = view
            position(panel)
            return
        }

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 44)

        let panel = NSPanel(
            contentRect: host.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        position(panel)
        panel.orderFrontRegardless()

        self.panel = panel
        self.host = host
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + 24))
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        host = nil
    }
}

private struct HUDView: View {
    let text: String
    let color: Color
    let showLevel: Bool
    let levelProvider: () -> Float

    @State private var pulse = false
    @State private var level: Float = 0
    private let levelTimer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                           value: pulse)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            if showLevel {
                LevelBars(level: level)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(.black.opacity(0.78)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { pulse = true }
        .onReceive(levelTimer) { _ in
            if showLevel { level = levelProvider() }
        }
    }
}

private struct LevelBars: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<6, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Float(index) / 6.0 < level ? Color.green : Color.white.opacity(0.25))
                    .frame(width: 3, height: 4 + CGFloat(index) * 2)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
