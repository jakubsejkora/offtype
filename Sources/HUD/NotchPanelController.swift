import AppKit
import SwiftUI
import OfftypeCore

// MARK: - Non-activating panel
//
// A borderless overlay that never takes focus or activates the app — it just
// floats. Clicking through to whatever is underneath is the whole point.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

/// Owns the two HUD windows: the notch overlay (the orb, anchored just right of
/// the MacBook notch) and a center-screen mirror (the full dashboard) for
/// projectors, where the notch edge clips. Both are always-on-top, join every
/// Space, float over full-screen apps, and ignore the mouse.
@MainActor
public final class NotchPanelController {
    private let model: HUDModel
    private let notchPanel: OverlayPanel
    private let mirrorPanel: OverlayPanel
    private let mirrorHost: NSHostingView<AnyView>
    // Set on the main actor, read once at dealloc — safe to access nonisolated.
    nonisolated(unsafe) private var screenObserver: (any NSObjectProtocol)?

    private let orbDiameter: CGFloat = 28
    private let notchMargin: CGFloat = 8

    public init(model: HUDModel) {
        self.model = model
        notchPanel = Self.makePanel()
        mirrorPanel = Self.makePanel()

        let notchHost = NSHostingView(
            rootView: AnyView(NotchOverlayView(model: model, orbDiameter: orbDiameter))
        )
        notchHost.autoresizingMask = [.width, .height]
        notchPanel.contentView = notchHost

        mirrorHost = NSHostingView(rootView: AnyView(HUDDashboardView(model: model)))
        mirrorHost.sizingOptions = [.intrinsicContentSize]
        mirrorPanel.contentView = mirrorHost

        observeScreens()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: Public API

    /// Show the notch orb. Safe to call repeatedly (also re-anchors).
    public func show() {
        positionNotch()
        notchPanel.orderFrontRegardless()
    }

    public func hide() { notchPanel.orderOut(nil) }

    /// Show the center-screen mirror (the projector / big-screen view).
    public func showMirror() {
        positionMirror()
        mirrorPanel.orderFrontRegardless()
    }

    public func hideMirror() { mirrorPanel.orderOut(nil) }

    public var isMirrorVisible: Bool { mirrorPanel.isVisible }

    public func toggleMirror() { isMirrorVisible ? hideMirror() : showMirror() }

    /// Show both surfaces — the default for a live demo.
    public func showAll() {
        show()
        showMirror()
    }

    public func hideAll() {
        hide()
        hideMirror()
    }

    // MARK: Panel factory

    private static func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        return panel
    }

    // MARK: Positioning

    private var activeScreen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    /// Anchor the orb's visual center just right of the notch, vertically centered
    /// on the menu bar. Falls back to a tidy top-center spot on notch-less displays.
    private func positionNotch() {
        guard let screen = activeScreen else { return }
        let reserved = orbDiameter * DynamicCircleView.reservedScale
        let panelW = reserved + 240
        let panelH = reserved

        let orbVisibleRadius = orbDiameter / 2
        let notchRightX: CGFloat
        if let aux = screen.auxiliaryTopRightArea {
            notchRightX = aux.minX                       // right edge of the notch
        } else {
            notchRightX = screen.frame.midX + 140 - notchMargin - orbVisibleRadius
        }
        let orbCenterX = notchRightX + notchMargin + orbVisibleRadius

        let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        let orbCenterY = screen.frame.maxY - menuBarHeight / 2

        // Orb center inside the leading-aligned overlay = (reserved/2, panelH/2).
        let originX = orbCenterX - reserved / 2
        let originY = orbCenterY - panelH / 2
        notchPanel.setFrame(NSRect(x: originX, y: originY, width: panelW, height: panelH), display: true)
    }

    /// Center the dashboard on the active screen, biased slightly above center.
    private func positionMirror() {
        guard let screen = activeScreen else { return }
        mirrorHost.layoutSubtreeIfNeeded()
        let size = mirrorHost.fittingSize
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2 + visible.height * 0.08
        mirrorPanel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func observeScreens() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    private func reposition() {
        if notchPanel.isVisible { positionNotch() }
        if mirrorPanel.isVisible { positionMirror() }
    }
}
