import AppKit
import SwiftUI

/// The LocalFlow notch: a persistent, draggable rounded-rectangle that lives at
/// the bottom-center of the screen and signals dictation state.
///
/// - Idle: a small rounded rect with a single white resting dot.
/// - Active (recording/transcribing/cleaning): the panel expands smoothly, a
///   noise ring appears around it, and a flip label reports the state. While
///   recording, live decibel bars are shown, driven by `levelProvider`.
///
/// Draggable anywhere for the current session (in-memory only) — it returns to
/// bottom-center on the next launch. Non-activating so it never steals focus
/// from the app you are dictating into.
@MainActor
final class RecordingHUD {
    private var panel: NSPanel?
    private var host: NSHostingView<NotchView>?

    /// The intended pill center. Follows user drags but is NOT perturbed by our
    /// own expand/collapse clamping, so the notch never "walks" across resizes.
    private var anchorCenter: CGPoint?
    private var moveObserver: NSObjectProtocol?
    private var programmaticMove = false

    /// Reads the current mic input level (0...1) while recording.
    var levelProvider: () -> Float = { 0 }

    private let idleSize = CGSize(width: 132, height: 40)
    private let activeSize = CGSize(width: 264, height: 92)

    func update(state: DictationController.State) {
        ensurePanel()
        guard let panel, let host else { return }
        host.rootView = NotchView(state: state, levelProvider: levelProvider)
        resize(panel, to: Self.isExpanded(state) ? activeSize : idleSize)
    }

    static func isExpanded(_ state: DictationController.State) -> Bool {
        switch state {
        case .recording, .transcribing, .cleaning: return true
        default: return false
        }
    }

    private func ensurePanel() {
        if panel != nil { return }

        let host = NSHostingView(rootView: NotchView(state: .idle, levelProvider: levelProvider))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: idleSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        // Must receive mouse events to be draggable — the trade-off is that the
        // notch's footprint now catches clicks that would fall through before.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.midX - idleSize.width / 2, y: vf.minY + 24))
        }
        anchorCenter = CGPoint(x: panel.frame.midX, y: panel.frame.midY)

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, !self.programmaticMove else { return }
                self.anchorCenter = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            }
        }

        panel.orderFrontRegardless()
        self.panel = panel
        self.host = host
    }

    /// Animate the panel to a new size around `anchorCenter`, clamped so the
    /// notch stays fully on-screen. The anchor itself is unchanged by clamping.
    private func resize(_ panel: NSPanel, to size: CGSize) {
        guard let anchor = anchorCenter, panel.frame.size != size else { return }
        var origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2)
        if let screen = panel.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            origin.x = min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - size.width))
            origin.y = min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - size.height))
        }
        let target = NSRect(origin: origin, size: size)

        programmaticMove = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.programmaticMove = false }
        })
    }

    func hide() {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        host = nil
    }
}

// MARK: - Notch view

private struct NotchView: View {
    let state: DictationController.State
    let levelProvider: () -> Float

    @State private var level: CGFloat = 0
    private let ticker = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var expanded: Bool { RecordingHUD.isExpanded(state) }
    private var isRecording: Bool { if case .recording = state { return true } else { return false } }

    /// Green while listening, orange while transcribing/cleaning, white at rest.
    private var accent: Color {
        switch state {
        case .recording: return .green
        case .transcribing, .cleaning: return .orange
        default: return .white
        }
    }

    private var statusText: String? {
        switch state {
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .cleaning: return "Cleaning up"
        default: return nil
        }
    }

    var body: some View {
        ZStack {
            if expanded {
                NoiseRing(accent: accent)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            pill
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: expanded)
        .animation(.easeInOut(duration: 0.25), value: statusText)
        .onReceive(ticker) { _ in
            let target = CGFloat(isRecording ? levelProvider() : 0)
            let next = level + (target - level) * 0.4
            if abs(next - level) > 0.001 { level = next }
        }
    }

    private var pill: some View {
        HStack(spacing: 9) {
            dot
            if let statusText {
                Text(statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .id(statusText)
                    .transition(.push(from: .bottom).combined(with: .opacity))
            }
            if isRecording {
                DecibelBars(level: level, accent: accent)
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
            }
        }
        .padding(.horizontal, expanded ? 16 : 13)
        .padding(.vertical, expanded ? 11 : 9)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .fixedSize()
    }

    @ViewBuilder private var dot: some View {
        if expanded {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                dotCircle(opacity: 0.55 + 0.45 * sin(t * 3.2), glow: true)
            }
        } else {
            dotCircle(opacity: 1, glow: false)
        }
    }

    private func dotCircle(opacity: Double, glow: Bool) -> some View {
        Circle()
            .fill(accent)
            .frame(width: 9, height: 9)
            .opacity(opacity)
            .shadow(color: glow ? accent.opacity(0.85) : .clear, radius: glow ? 5 : 0)
    }
}

// MARK: - Noise ring (Aceternity "noise-background", reimplemented in SwiftUI)

private struct NoiseRing: View {
    let accent: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                // Rotating gradient glow.
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                accent.opacity(0.0), accent.opacity(0.9),
                                accent.opacity(0.2), accent.opacity(0.9),
                                accent.opacity(0.0),
                            ]),
                            center: .center,
                            angle: .degrees(t.truncatingRemainder(dividingBy: 6) / 6 * 360)),
                        lineWidth: 6)
                    .blur(radius: 9)
                    .padding(9)

                // Crisp inner ring that breathes.
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(accent.opacity(0.30 + 0.15 * sin(t * 3)), lineWidth: 1.5)
                    .padding(13)

                // Static grain, masked to the ring band.
                NoiseOverlay()
                    .opacity(0.45)
                    .mask(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(lineWidth: 16)
                            .padding(11))
            }
        }
    }
}

/// A cheap, deterministic film-grain: a fixed cloud of tiny dots (seeded once,
/// no per-frame randomness) that reads as noise texture over the ring.
private struct NoiseOverlay: View {
    private let points: [CGPoint]

    init() {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func rnd() -> CGFloat {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return CGFloat(seed % 1000) / 1000
        }
        points = (0..<240).map { _ in CGPoint(x: rnd(), y: rnd()) }
    }

    var body: some View {
        Canvas { ctx, size in
            for p in points {
                let rect = CGRect(x: p.x * size.width, y: p.y * size.height, width: 1, height: 1)
                ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.35)))
            }
        }
    }
}

// MARK: - Decibel bars

private struct DecibelBars: View {
    let level: CGFloat
    let accent: Color
    private let count = 7

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { i in
                    let phase = (sin(t * 6 + Double(i) * 0.9) + 1) / 2
                    let base: CGFloat = 4
                    let dynamic = level * 22 * (0.55 + 0.45 * CGFloat(phase))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accent)
                        .frame(width: 3, height: max(base, base + dynamic))
                }
            }
            .frame(height: 26)
        }
    }
}
