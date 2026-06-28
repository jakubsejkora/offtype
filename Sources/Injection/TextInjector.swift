import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox
import os
import OfftypeCore

/// Injects final text into whatever app has focus by temporarily borrowing the
/// pasteboard and synthesizing ⌘V.
///
/// Contract (`TextInjecting`):
///  * If a **secure input field** is focused (`IsSecureEventInputEnabled()`),
///    return `false` *without throwing* so the caller falls back to in-app
///    rendering — we must never paste into a password field.
///  * Otherwise: snapshot the **entire** pasteboard (every item, every type),
///    write our string, post ⌘V, and **restore** the snapshot a moment later so
///    the user's clipboard is left exactly as it was. No clipboard theft.
///
/// Requires Accessibility to post the synthetic keystroke.
public struct TextInjector: TextInjecting {
    public init() {}

    /// How long to wait before restoring the user's clipboard, giving the focused
    /// app time to read our pasted string first.
    static let restoreDelay: TimeInterval = 0.2

    /// Whether a secure input field (password field, etc.) is currently active.
    public static func isSecureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    @discardableResult
    public func inject(_ text: String) throws -> Bool {
        if Self.isSecureInputActive() {
            Log.inject.notice("Injection refused: secure input is active")
            return false
        }

        let pasteboard = NSPasteboard.general
        let snapshot = Self.snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Log.inject.debug("Injecting \(text.count, privacy: .public) chars: \(text, privacy: .private)")

        Self.postPasteKeystroke()

        // Restore on a background queue after the paste has had time to land.
        // Re-fetch the pasteboard by name inside the closure rather than
        // capturing the (non-Sendable) instance.
        let name = pasteboard.name
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.restoreDelay) {
            Self.restore(snapshot, to: NSPasteboard(name: name))
        }

        return true
    }

    // MARK: - Pasteboard save / restore (testable on any named pasteboard)

    /// A full snapshot of a pasteboard: per item, a map of type → raw bytes.
    struct PasteboardSnapshot: Sendable, Equatable {
        var items: [[String: Data]]
    }

    /// Capture every item and every type currently on `pasteboard`.
    static func snapshot(of pasteboard: NSPasteboard) -> PasteboardSnapshot {
        var items: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entry: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type.rawValue] = data
                }
            }
            if !entry.isEmpty {
                items.append(entry)
            }
        }
        return PasteboardSnapshot(items: items)
    }

    /// Overwrite `pasteboard` with a previously captured snapshot.
    static func restore(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard?) {
        guard let pasteboard else { return }
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.items.map { entry in
            let item = NSPasteboardItem()
            for (rawType, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // MARK: - Keystroke synthesis

    /// Post a ⌘V key-down / key-up pair (virtual keycode 9 == 'v').
    static func postPasteKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            Log.inject.error("Injection: failed to create ⌘V key events")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
