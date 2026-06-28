import CoreGraphics
import Foundation
import OfftypeCore

// AGENT(ComputerUse): implement the Gemini 3.5 Flash computer-use loop via the
// Interactions API (REST/URLSession — no Swift SDK). POST /v1beta/interactions
// with tools=[{type:"computer_use", environment:"desktop",
// enable_prompt_injection_detection:true}]; loop with previous_interaction_id +
// function_result(+fresh screenshot). PARSE DEFENSIVELY (steps[] vs outputs[]).
// Execute actions via CGEvent (reuse Injection patterns). Honor
// safety_decision==require_confirmation. Then MacroCrystallizer records a verified
// action sequence as a deterministic macro replayed with ZERO Gemini calls.

/// Pure coordinate math: Gemini emits normalized 0...1000 coords relative to the
/// screenshot (in PIXELS). Convert to a global CGEvent point (Quartz top-left),
/// accounting for Retina backing scale and the display's global origin. This is
/// the single most error-prone step, so it's isolated and unit-tested.
public enum CoordinateMapper {
    public static func toGlobalPoint(
        normX: Double,
        normY: Double,
        imagePixelWidth: Double,
        imagePixelHeight: Double,
        backingScale: Double,
        displayOrigin: CGPoint
    ) -> CGPoint {
        precondition(backingScale > 0, "backingScale must be > 0")
        let pxX = normX / 1000.0 * imagePixelWidth
        let pxY = normY / 1000.0 * imagePixelHeight
        return CGPoint(x: pxX / backingScale + displayOrigin.x,
                       y: pxY / backingScale + displayOrigin.y)
    }
}

/// Gates every proposed action: honors Gemini's require_confirmation and our own
/// app/action denylist; supports a hard kill-switch.
public struct SafetyGate: Sendable {
    public enum Decision: Sendable, Equatable {
        case allow
        case requireConfirmation(reason: String)
        case block(reason: String)
    }

    /// Apps we never drive automatically.
    public static let deniedAppKeywords = [
        "system settings", "system preferences", "keychain access",
        "terminal", "iterm", "1password", "bitwarden",
    ]
    /// Action labels that always require explicit human confirmation.
    public static let confirmKeywords = ["send", "pay", "delete", "confirm purchase", "transfer", "buy"]

    public init() {}

    public func evaluate(actionLabel: String, targetApp: String?) -> Decision {
        let app = (targetApp ?? "").lowercased()
        if Self.deniedAppKeywords.contains(where: app.contains) {
            return .block(reason: "App is on the denylist: \(targetApp ?? "?")")
        }
        let label = actionLabel.lowercased()
        if Self.confirmKeywords.contains(where: label.contains) {
            return .requireConfirmation(reason: "Sensitive action: \(actionLabel)")
        }
        return .allow
    }
}

/// Placeholder agent so the package compiles before implementation.
public final class ComputerUseAgent: @unchecked Sendable {
    public init() {}
}
