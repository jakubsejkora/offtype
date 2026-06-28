import OfftypeCore

// AGENT(Hotkey): implement a CGEventTap on `.flagsChanged` that detects the
// RIGHT Command key (keycode 54 / device-flag bit 0x10) for hold-to-talk, plus a
// Right-Cmd+Space toggle for hands-free. Handle `tapDisabledByTimeout` re-enable.
// Requires Input Monitoring (+ Accessibility). Expose start/stop and callbacks:
//   var onPressStart: (@Sendable () -> Void)?
//   var onPressEnd:   (@Sendable () -> Void)?
//   var onToggle:     (@Sendable () -> Void)?

/// Placeholder so the package compiles before implementation.
public final class HotkeyMonitor: @unchecked Sendable {
    public init() {}
    public func start() {}
    public func stop() {}
}
