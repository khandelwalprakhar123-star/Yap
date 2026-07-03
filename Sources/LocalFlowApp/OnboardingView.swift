import AVFoundation
import LocalFlowCore
import SwiftUI

/// Permission checklist shown on first launch (and from the menu).
/// Polls each permission every second so rows flip to green as they're granted.
struct OnboardingView: View {
    @State private var micGranted = AudioRecorder.microphonePermissionGranted()
    @State private var inputMonitoringGranted = HotkeyListener.inputMonitoringGranted()
    @State private var accessibilityGranted = TextInjector.accessibilityGranted()

    let onAllGranted: () -> Void
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("LocalFlow needs two permissions")
                .font(.title2).bold()
            Text("Everything runs on this Mac. No audio or text ever leaves your machine.")
                .foregroundStyle(.secondary)

            permissionRow(
                granted: micGranted,
                title: "Microphone",
                detail: "Records your voice while the hotkey is held.",
                buttonTitle: "Grant",
                action: {
                    Task { _ = await AudioRecorder.requestMicrophonePermission() }
                },
                pane: "Privacy_Microphone"
            )
            permissionRow(
                granted: accessibilityGranted,
                title: "Accessibility",
                detail: "Detects the push-to-talk key and pastes the transcribed text. "
                    + "In System Settings, find LocalFlow in the list and switch it on — "
                    + "if it's missing, click + and add dist/LocalFlow.app.",
                buttonTitle: "Grant",
                action: { TextInjector.requestAccessibility() },
                pane: "Privacy_Accessibility"
            )
            permissionRow(
                granted: inputMonitoringGranted,
                title: "Input Monitoring (optional)",
                detail: "Only needed for F-key hotkeys (F13–F15). Modifier keys like "
                    + "Right Option work with Accessibility alone.",
                buttonTitle: "Grant",
                action: { HotkeyListener.requestInputMonitoring() },
                pane: "Privacy_ListenEvent"
            )

            if micGranted && accessibilityGranted {
                Label("All set — hold your hotkey anywhere and start talking.",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .padding(.top, 4)
            } else {
                Text("Tip: if a permission was just granted but LocalFlow doesn't react, quit and reopen the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onReceive(timer) { _ in
            micGranted = AudioRecorder.microphonePermissionGranted()
            inputMonitoringGranted = HotkeyListener.inputMonitoringGranted()
            accessibilityGranted = TextInjector.accessibilityGranted()
            if micGranted && accessibilityGranted {
                onAllGranted()
            }
        }
    }

    @ViewBuilder
    private func permissionRow(
        granted: Bool, title: String, detail: String,
        buttonTitle: String, action: @escaping () -> Void, pane: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(buttonTitle, action: action)
                Button("Open Settings") {
                    let url = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
                    if let settingsURL = URL(string: url) { NSWorkspace.shared.open(settingsURL) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}
