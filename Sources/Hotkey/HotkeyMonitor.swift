import Foundation
import CoreGraphics
import ApplicationServices
import IOKit.hid
import os
import OfftypeCore

// MARK: - Key / flag constants
//
// We distinguish the RIGHT Command key from the left one via the device-dependent
// flag bit NX_DEVICERCMDKEYMASK (0x10), which is set in the event flags only while
// right-Command is physically down (left-Command is 0x08). This is keyed off the
// flag transition rather than keycode 54 (0x36, the right-Command keycode; left is
// 55) so it stays correct when other modifiers change within the same gesture.
private let kSpaceKeyCode: Int64 = 49
private let kRightCommandDeviceMask: UInt64 = 0x10 // NX_DEVICERCMDKEYMASK

/// Snapshot of the two TCC grants the hotkey tap needs. Querying never prompts
/// and never crashes — it just reports current status so the UI can guide the user.
public struct HotkeyPermissions: Sendable, Equatable {
    /// `AXIsProcessTrusted()` — required to *post* synthetic events (injection)
    /// and, in practice, for a session event tap to deliver events.
    public var accessibility: Bool
    /// `IOHIDCheckAccess(.listenEvent)` — required to observe keystrokes.
    public var inputMonitoring: Bool

    public var allGranted: Bool { accessibility && inputMonitoring }

    public init(accessibility: Bool, inputMonitoring: Bool) {
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
    }
}

/// Global, hold-to-talk hotkey listener built on a `CGEventTap`.
///
/// Behaviour the composition root wires to:
///  * **Hold-to-talk:** press RIGHT Command → `onPressStart`; release → `onPressEnd`.
///  * **Hands-free toggle:** Right-Command+Space → `onToggle` (the Space keystroke
///    is swallowed so it never types). When Space is chorded, the right-Command
///    release that follows does **not** fire `onPressEnd` — the toggle "owns" the
///    session instead, so the recording survives the key release.
///
/// The tap runs on a dedicated thread with its own run loop so it never contends
/// with the main run loop, and it self-heals if the system disables it.
///
/// `@unchecked Sendable`: all externally-mutable state (the callbacks and the tap
/// lifecycle handles) is guarded by `lock`; the gesture state machine
/// (`rightCmdDown` / `chordConsumed`) is confined to the tap thread.
public final class HotkeyMonitor: @unchecked Sendable {
    // Lifecycle handles — guarded by `lock`.
    private let lock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoopRef: CFRunLoop?
    private var thread: Thread?

    // Callbacks — guarded by `lock` (settable from any thread, read on tap thread).
    private var _onPressStart: (@Sendable () -> Void)?
    private var _onPressEnd: (@Sendable () -> Void)?
    private var _onToggle: (@Sendable () -> Void)?

    /// Right-Command pressed (hold-to-talk begins). Fired on the tap thread.
    public var onPressStart: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onPressStart }
        set { lock.lock(); _onPressStart = newValue; lock.unlock() }
    }
    /// Right-Command released without a chord (hold-to-talk ends). Fired on the tap thread.
    public var onPressEnd: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onPressEnd }
        set { lock.lock(); _onPressEnd = newValue; lock.unlock() }
    }
    /// Right-Command+Space chord (hands-free toggle). Fired on the tap thread.
    public var onToggle: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onToggle }
        set { lock.lock(); _onToggle = newValue; lock.unlock() }
    }

    // Gesture state — touched ONLY on the tap thread, so it needs no lock.
    private var rightCmdDown = false
    private var chordConsumed = false

    public init() {}

    deinit { stop() }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }; return thread != nil
    }

    // MARK: - Permissions

    /// Current TCC status for the hotkey tap. Pure query — never prompts, never crashes.
    public static func permissionStatus() -> HotkeyPermissions {
        let ax = AXIsProcessTrusted()
        let hid = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        return HotkeyPermissions(accessibility: ax, inputMonitoring: hid)
    }

    // MARK: - Lifecycle

    /// Start listening. Idempotent. If the tap can't be created (permissions not
    /// yet granted), this logs and returns without crashing; call again after the
    /// user grants Input Monitoring / Accessibility.
    public func start() {
        lock.lock()
        if thread != nil {
            lock.unlock()
            return
        }
        let t = Thread { [weak self] in
            self?.runTapLoop()
        }
        t.name = "\(Log.subsystem).hotkey"
        t.qualityOfService = .userInteractive
        thread = t
        lock.unlock()
        t.start()
    }

    /// Stop listening and tear the tap down. Idempotent.
    public func stop() {
        lock.lock()
        let tap = eventTap
        let rl = runLoopRef
        lock.unlock()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let rl {
            CFRunLoopStop(rl)
        }
    }

    // MARK: - Tap thread

    private func runTapLoop() {
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: refcon
        ) else {
            Log.app.error("Hotkey: failed to create event tap — Input Monitoring / Accessibility not granted?")
            lock.lock(); thread = nil; lock.unlock()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let rl = CFRunLoopGetCurrent()

        lock.lock()
        eventTap = tap
        runLoopSource = source
        runLoopRef = rl
        lock.unlock()

        CFRunLoopAddSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        rightCmdDown = false
        chordConsumed = false
        Log.app.notice("Hotkey: event tap started")

        CFRunLoopRun() // blocks until CFRunLoopStop (from stop())

        // Teardown
        CFRunLoopRemoveSource(rl, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)

        lock.lock()
        eventTap = nil
        runLoopSource = nil
        runLoopRef = nil
        thread = nil
        lock.unlock()
        Log.app.notice("Hotkey: event tap stopped")
    }

    // MARK: - Event handling (tap thread only)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The OS disabled us (slow callback or user input storm). Re-arm.
            lock.lock(); let tap = eventTap; lock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Log.app.notice("Hotkey: tap re-enabled after disable (\(type.rawValue))")
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let rcmd = (event.flags.rawValue & kRightCommandDeviceMask) != 0
            if rcmd != rightCmdDown {
                rightCmdDown = rcmd
                if rcmd {
                    chordConsumed = false
                    snapshotPressStart()?()
                } else {
                    let consumed = chordConsumed
                    chordConsumed = false
                    if !consumed { snapshotPressEnd()?() }
                }
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            if isSpaceWithRightCommand(event) {
                // Fire once per physical press (ignore auto-repeat) and swallow
                // the Space so it never types into the focused field.
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    chordConsumed = true
                    snapshotToggle()?()
                }
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .keyUp:
            // Swallow the matching Space key-up so no stray event leaks through.
            if isSpaceWithRightCommand(event) {
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func isSpaceWithRightCommand(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventKeycode) == kSpaceKeyCode else { return false }
        let rcmdNow = rightCmdDown || (event.flags.rawValue & kRightCommandDeviceMask) != 0
        return rcmdNow
    }

    // Snapshot a callback under the lock and return it so the caller can invoke
    // it OUTSIDE the lock — a slow consumer can never deadlock the tap thread or
    // block `start`/`stop`.
    private func snapshotPressStart() -> (@Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }; return _onPressStart
    }
    private func snapshotPressEnd() -> (@Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }; return _onPressEnd
    }
    private func snapshotToggle() -> (@Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }; return _onToggle
    }
}

// MARK: - C trampoline
//
// CGEventTap takes a C function pointer, which cannot capture context. We pass
// the monitor as `refcon` and recover it here. `passUnretained` avoids a retain
// cycle — the composition root owns the monitor for the tap's lifetime.
private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
