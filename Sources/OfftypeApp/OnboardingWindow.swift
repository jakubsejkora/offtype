import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import Observation
import OfftypeCore
import Hotkey
import HUD

// MARK: - First-run onboarding + live permissions
//
// A polished, on-brand welcome that states the privacy posture up front and walks
// the user through the four TCC grants Offtype can use. The checklist is LIVE: a
// background poll re-reads each grant every 1.5s, so a row flips amber → emerald
// the instant the user toggles it in System Settings — no relaunch, no refresh
// button. Core dictation needs only Microphone + Input Monitoring + Accessibility;
// Screen Recording is optional and only relevant to screen-awareness / cloud
// computer-use.
//
// Everything (window, controller, model, views) is self-contained in this file.
// The app's only entry points are `OnboardingWindow.present()` /
// `presentIfNeeded()`.

// MARK: - Public entry point

/// The app-facing handle to the onboarding window. Reuses a single window
/// instance so it can be re-presented on demand from the menu.
@MainActor
public enum OnboardingWindow {
    /// Lazily-built, kept alive across closes (the window's `isReleasedWhenClosed`
    /// is false) so re-presenting preserves the user's window position.
    private static var controller: OnboardingWindowController?

    /// "We've shown the welcome at least once" — namespaced under the app's
    /// logging subsystem so it never collides with other defaults.
    private static let firstRunDefaultsKey = "\(Log.subsystem).onboardingShown"

    /// Show the onboarding window, creating it on first use, and bring it forward.
    public static func present() {
        let controller = controller ?? {
            let made = OnboardingWindowController()
            self.controller = made
            return made
        }()
        controller.show()
        UserDefaults.standard.set(true, forKey: firstRunDefaultsKey)
    }

    /// Show the window only when it would actually help: the first launch ever, or
    /// any launch where a core permission is missing (e.g. the user revoked one).
    /// Stays out of the way on healthy, already-onboarded launches.
    public static func presentIfNeeded() {
        let shownBefore = UserDefaults.standard.bool(forKey: firstRunDefaultsKey)
        if shownBefore && Self.coreGranted {
            Log.app.info("Onboarding: skipped (already shown, core permissions granted)")
            return
        }
        Log.app.notice("Onboarding: presenting (firstRun: \(!shownBefore, privacy: .public), coreGranted: \(Self.coreGranted, privacy: .public))")
        present()
    }

    /// Close the window. Called by the view's "Get Started" / "Skip for now"
    /// actions; goes through the metatype so the SwiftUI closures capture nothing
    /// retainable (no controller ⇄ view cycle).
    static func dismiss() {
        controller?.close()
    }

    /// The three grants the core dictation loop requires, queried without prompting.
    private static var coreGranted: Bool {
        let hotkey = HotkeyMonitor.permissionStatus()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        return hotkey.accessibility && hotkey.inputMonitoring && mic
    }
}

// MARK: - Window controller

/// Hosts the SwiftUI onboarding view in a borderless-titlebar window and owns the
/// permission poll's lifetime (running only while the window is visible).
@MainActor
private final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model = PermissionsModel()

    override init() {
        let hosting = NSHostingView(
            rootView: OnboardingView(model: model, onDismiss: { OnboardingWindow.dismiss() })
        )
        hosting.sizingOptions = [.intrinsicContentSize]

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        // Seamless dark chrome: content extends under a transparent title bar,
        // leaving only the close traffic light visible.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Offtype"
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(srgbRed: 11 / 255, green: 14 / 255, blue: 20 / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self

        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.setContentSize(hosting.fittingSize)
    }

    /// Start polling and bring the window forward. Re-centres only on a fresh show
    /// so the user's manual placement survives a re-present.
    func show() {
        model.startPolling()
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close() // → windowWillClose stops the poll
    }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
    }
}

// MARK: - Permissions model

/// Observable snapshot of the four TCC grants, refreshed on a timer so the UI
/// reflects System Settings live. Pure status reads here never prompt; the only
/// prompting action is the explicit microphone request.
@MainActor
@Observable
private final class PermissionsModel {
    /// Observe keystrokes — needed to detect the Right-Command hold-to-talk hotkey.
    var inputMonitoring = false
    /// Post synthetic events — needed to inject transcribed text into the focused app.
    var accessibility = false
    /// Microphone authorization (`.notDetermined` first, so we can offer "Request").
    var microphone: AVAuthorizationStatus = .notDetermined
    /// Screen Recording — optional; only screen-awareness / computer-use use it.
    var screenRecording = false

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    var micGranted: Bool { microphone == .authorized }

    /// The three grants that gate "Get Started" — everything dictation needs.
    var coreGranted: Bool { inputMonitoring && accessibility && micGranted }

    var coreReadyCount: Int {
        var n = 0
        if inputMonitoring { n += 1 }
        if accessibility { n += 1 }
        if micGranted { n += 1 }
        return n
    }

    func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .inputMonitoring: inputMonitoring
        case .accessibility: accessibility
        case .microphone: micGranted
        case .screenRecording: screenRecording
        }
    }

    // MARK: Polling

    /// Refresh now, then re-check every 1.5s until stopped. Idempotent.
    func startPolling() {
        refresh()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                if Task.isCancelled { break }
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func refresh() {
        let hotkey = HotkeyMonitor.permissionStatus()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let screen = CGPreflightScreenCaptureAccess()

        let changed = hotkey.inputMonitoring != inputMonitoring
            || hotkey.accessibility != accessibility
            || mic != microphone
            || screen != screenRecording
        if changed {
            Log.app.info("Onboarding permissions — input:\(hotkey.inputMonitoring, privacy: .public) ax:\(hotkey.accessibility, privacy: .public) mic:\(mic == .authorized, privacy: .public) screen:\(screen, privacy: .public)")
        }

        // Animate the row flips so a granted permission lands with a satisfying snap.
        withAnimation(.snappy(duration: 0.3)) {
            inputMonitoring = hotkey.inputMonitoring
            accessibility = hotkey.accessibility
            microphone = mic
            screenRecording = screen
        }
    }

    // MARK: Side-effecting actions (kept on the main actor)

    /// Trigger the system microphone prompt; refresh as soon as the user answers.
    func requestMicrophone() {
        Log.app.info("Onboarding: requesting microphone access")
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Deep-link straight to the relevant System Settings privacy pane.
    func openSettings(for kind: PermissionKind) {
        guard let url = kind.settingsURL else {
            Log.app.error("Onboarding: bad settings URL for \(kind.title, privacy: .public)")
            return
        }
        Log.app.info("Onboarding: opening Settings for \(kind.title, privacy: .public)")
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Permission catalogue

/// The four grants Offtype can use, with their copy, icon, and Settings deep-link.
private enum PermissionKind: CaseIterable, Identifiable {
    case inputMonitoring
    case accessibility
    case microphone
    case screenRecording

    var id: Self { self }

    var title: String {
        switch self {
        case .inputMonitoring: "Input Monitoring"
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        }
    }

    /// One line on *why* — the user should never have to guess what a grant buys.
    var why: String {
        switch self {
        case .inputMonitoring: "Detects the Right-Command hold-to-talk hotkey."
        case .accessibility: "Inserts the transcribed text into the focused app."
        case .microphone: "Captures your voice for on-device transcription."
        case .screenRecording: "Only for optional screen-awareness & computer-use."
        }
    }

    var icon: String {
        switch self {
        case .inputMonitoring: "keyboard"
        case .accessibility: "text.cursor"
        case .microphone: "mic.fill"
        case .screenRecording: "display"
        }
    }

    /// Core dictation never needs this one.
    var isOptional: Bool { self == .screenRecording }

    var settingsURL: URL? {
        let anchor: String
        switch self {
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .microphone: anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

// MARK: - Root view

private struct OnboardingView: View {
    let model: PermissionsModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            privacyPills
            permissionsSection
            coreNote
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 32)
        .padding(.top, 30)
        .padding(.bottom, 26)
        .frame(width: 560)
        .background { OnboardingBackground() }
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            BrandOrb()
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Offtype")
                    .font(.hudNumber(28, .heavy))
                    .foregroundStyle(HUDPalette.ink)
                Text("Runs entirely on your Mac. Nothing leaves your device by default.")
                    .font(.hudLabel(13, .medium))
                    .foregroundStyle(HUDPalette.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var privacyPills: some View {
        HStack(spacing: 8) {
            Pill("Private by default", systemImage: "lock.fill", tint: HUDPalette.local, filled: true)
            Pill("On-device STT", systemImage: "cpu", tint: HUDPalette.signal)
            Pill("No telemetry", systemImage: "eye.slash", tint: HUDPalette.inkDim)
        }
    }

    // MARK: Permission checklist

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow("Permissions")
                Spacer()
                coreProgress
            }
            VStack(spacing: 0) {
                ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element) { index, kind in
                    if index > 0 { rowDivider }
                    PermissionRowView(kind: kind, model: model)
                }
            }
            .padding(.vertical, 4)
            .glassCard()
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(HUDPalette.hairline)
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    /// A compact "Core 2/3" tally that turns emerald the moment all three land.
    private var coreProgress: some View {
        let done = model.coreReadyCount == 3
        let tint = done ? HUDPalette.local : HUDPalette.inkDim
        return HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.seal.fill" : "circle.dotted")
                .font(.system(size: 11, weight: .bold))
            Text("Core \(model.coreReadyCount)/3")
                .font(.hudLabel(11, .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background { Capsule().fill(tint.opacity(0.14)) }
        .animation(.snappy(duration: 0.3), value: model.coreReadyCount)
    }

    private var coreNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(HUDPalette.inkDim)
            Text("Core dictation needs only Microphone, Input Monitoring, and Accessibility. Screen Recording is optional — requested only if you turn on cloud computer-use.")
                .font(.hudLabel(11, .medium))
                .foregroundStyle(HUDPalette.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Button("Skip for now", action: onDismiss)
                .buttonStyle(QuietLinkButtonStyle())

            Spacer(minLength: 0)

            if !model.coreGranted {
                Text("Grant the 3 core permissions to continue")
                    .font(.hudLabel(11, .medium))
                    .foregroundStyle(HUDPalette.inkDim)
                    .transition(.opacity)
            }

            Button(action: onDismiss) {
                HStack(spacing: 6) {
                    Text(model.coreGranted ? "Get Started" : "Get Started")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(!model.coreGranted)
        }
        .animation(.snappy(duration: 0.3), value: model.coreGranted)
    }
}

// MARK: - Permission row

private struct PermissionRowView: View {
    let kind: PermissionKind
    let model: PermissionsModel

    private var granted: Bool { model.isGranted(kind) }
    /// Emerald once granted, amber while pending — the whole row's accent flips.
    private var statusTint: Color { granted ? HUDPalette.local : HUDPalette.cloud }

    var body: some View {
        HStack(spacing: 14) {
            iconTile
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(kind.title)
                        .font(.hudNumber(14, .semibold))
                        .foregroundStyle(HUDPalette.ink)
                    if kind.isOptional {
                        Pill("Optional", tint: HUDPalette.inkDim)
                    }
                }
                Text(kind.why)
                    .font(.hudLabel(11, .medium))
                    .foregroundStyle(HUDPalette.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .animation(.snappy(duration: 0.3), value: granted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.title). \(kind.why)")
        .accessibilityValue(granted ? "Granted" : "Pending")
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(statusTint.opacity(0.14))
            .frame(width: 38, height: 38)
            .overlay {
                Image(systemName: kind.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusTint)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(statusTint.opacity(0.28), lineWidth: 1)
            }
    }

    @ViewBuilder
    private var trailing: some View {
        if granted {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                Text("Ready")
            }
            .font(.hudLabel(12, .bold))
            .foregroundStyle(HUDPalette.local)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background { Capsule().fill(HUDPalette.local.opacity(0.14)) }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else if kind == .microphone && model.microphone == .notDetermined {
            Button("Request") { model.requestMicrophone() }
                .buttonStyle(CapsuleButtonStyle(tint: HUDPalette.cloud, filled: true))
        } else {
            Button { model.openSettings(for: kind) } label: {
                HStack(spacing: 5) {
                    Text("Open Settings")
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .buttonStyle(CapsuleButtonStyle(tint: HUDPalette.cloud))
        }
    }
}

// MARK: - Brand orb

/// A small emerald orb echoing the HUD's Dynamic Circle — the app's identity mark,
/// in the same "local / free / instant" green that carries the whole thesis.
private struct BrandOrb: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [HUDPalette.local, HUDPalette.local.opacity(0.35)],
                        center: .center, startRadius: 1, endRadius: 28
                    )
                )
            Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            Image(systemName: "waveform")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.78))
        }
        .frame(width: 52, height: 52)
        .shadow(color: HUDPalette.local.opacity(0.45), radius: 14)
        .accessibilityHidden(true)
    }
}

// MARK: - Background

/// Dark, faintly two-tone backdrop matching the HUD dashboard so the onboarding
/// window reads as the same product.
private struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(.sRGB, red: 11 / 255, green: 14 / 255, blue: 20 / 255, opacity: 1),
                    Color(.sRGB, red: 17 / 255, green: 22 / 255, blue: 33 / 255, opacity: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [HUDPalette.local.opacity(0.12), .clear],
                center: .topTrailing, startRadius: 0, endRadius: 440
            )
            RadialGradient(
                colors: [HUDPalette.signal.opacity(0.08), .clear],
                center: .bottomLeading, startRadius: 0, endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Button styles

/// The capsule used by per-row "Open Settings" / "Request" actions; mirrors the
/// HUD `Pill` so controls and labels share one visual language.
private struct CapsuleButtonStyle: ButtonStyle {
    var tint: Color
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.hudLabel(12, .semibold))
            .foregroundStyle(filled ? Color.black.opacity(0.85) : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule(style: .continuous)
                    .fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(filled ? 0 : 0.5), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// The primary "Get Started" call to action. Emerald→cyan when enabled, recedes
/// to a quiet well when the core permissions aren't in yet.
private struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration)
    }

    private struct ButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.hudNumber(14, .bold))
                .foregroundStyle(isEnabled ? Color.black.opacity(0.9) : HUDPalette.inkDim)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background {
                    Capsule(style: .continuous)
                        .fill(
                            isEnabled
                                ? AnyShapeStyle(
                                    LinearGradient(
                                        colors: [HUDPalette.local, HUDPalette.signal],
                                        startPoint: .leading, endPoint: .trailing
                                    ))
                                : AnyShapeStyle(HUDPalette.well)
                        )
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(isEnabled ? 0.16 : 0.06), lineWidth: 1)
                }
                .shadow(color: isEnabled ? HUDPalette.local.opacity(0.4) : .clear, radius: 10, y: 4)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.snappy(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// A quiet text link for "Skip for now".
private struct QuietLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.hudLabel(12, .semibold))
            .foregroundStyle(HUDPalette.inkDim)
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

// MARK: - Preview

#Preview("Onboarding — two of three ready") {
    let model = PermissionsModel()
    model.inputMonitoring = true
    model.accessibility = true
    model.microphone = .notDetermined
    model.screenRecording = false
    return OnboardingView(model: model, onDismiss: {})
}
