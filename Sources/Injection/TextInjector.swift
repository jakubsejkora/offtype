import OfftypeCore

// AGENT(Injection): implement pasteboard save → set string → synthesize ⌘V via
// CGEvent → restore pasteboard after a short delay. MUST check
// `IsSecureEventInputEnabled()` first and return false (no throw) so the caller
// can fall back to in-app rendering. Save/restore ALL pasteboard items, not just
// the string (no clipboard theft). Requires Accessibility.

/// Placeholder conforming type so the package compiles before implementation.
public struct TextInjector: TextInjecting {
    public init() {}

    @discardableResult
    public func inject(_ text: String) throws -> Bool {
        // TODO(Injection): real pasteboard+⌘V with secure-input guard.
        false
    }

    /// Whether a secure input field is currently active (password fields, etc.).
    public static func isSecureInputActive() -> Bool { false }
}
